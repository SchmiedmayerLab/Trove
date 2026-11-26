//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import Testing
import TroveAPIServer
import TroveAPITypes
@testable import TroveServer
import VaporTesting


/// Publication requires the readiness facts, an approval for each administration language of each Questionnaire,
/// complete translations into each of them, and an available route for each required collection requirement.
struct PublicationReadinessTests {
    private static var authority: GrantorAuthorityProvider {
        .init { actor in
            .init(issuer: actor.issuer, subject: actor.subject, enabled: true, roles: [TestApp.researcherRole], groups: ["/Test Group/admin"])
        }
    }

    private static func withApp(_ test: @escaping @Sendable (Application, String?) async throws -> Void) async throws {
        try await TestApp.withApp(validator: QuestionnaireWorkerReply.validator(), grantorAuthority: authority, test)
    }

    @Test
    func missingReadinessFactsBlockWithFieldRuleAndNextAction() async throws {
        try await Self.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            var facts = StudyFixtures.completeReadinessFacts()
            facts.content.additionalProperties["en"]?.burden = "   "
            facts.contacts = [.init(name: "Coordinator", role: "", email: "not-an-address")]
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId(), readinessFacts: facts)
            let report = try await Self.validate(study.requireId(), app: app, token: token)
            #expect(report.status == .invalid && report.candidate == nil)
            let burden = try #require(report.blockers.first { $0.rule == "readiness-burden-missing" })
            #expect(burden.path == "readinessFacts.content.en.burden" && burden.source == .trove && burden.nextAction != nil)
            #expect(report.blockers.contains { $0.rule == "readiness-contact-incomplete" && $0.path == "readinessFacts.contacts[0]" })
            #expect(report.blockers.contains { $0.rule == "readiness-contact-email" && $0.path == "readinessFacts.contacts[0].email" })
            #expect(try await StudyPublicationCandidate.query(on: app.db).count() == 0)

            let patched = try await Self.patch(study.requireId(), app: app, token: token, readiness: StudyFixtures.completeReadinessFacts())
            #expect(patched.readinessFacts == StudyFixtures.completeReadinessFacts())
            let valid = try await Self.validate(study.requireId(), app: app, token: token)
            #expect(valid.status == .valid && valid.blockers.isEmpty)
        }
    }

    @Test
    func readinessFactsInOtherDetailsLanguagesAreAdvisories() async throws {
        try await Self.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let german = try #require(LanguageTag(rawValue: "de"))
            let english = try #require(LanguageTag(rawValue: "en"))
            study.details = try #require(StudyDetailData(
                sourceLanguage: english, content: [english: .init(title: "Study"), german: .init(title: "Studie")]
            ))
            try await study.save(on: app.db)
            let report = try await Self.validate(study.requireId(), app: app, token: token)
            #expect(report.status == .valid)
            #expect(report.advisories.contains { $0.rule == "readiness-translation-missing" && $0.path == "readinessFacts.content.de" })
        }
    }

    @Test
    func readinessFactsOutsideTheirBoundsAreRejected() async throws {
        try await Self.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            var facts = StudyFixtures.completeReadinessFacts()
            facts.content.additionalProperties["not a tag"] = .init(aims: "Aims")
            let response = try await Self.patchResponse(study.requireId(), revision: study.draftRevision, app: app, token: token, readiness: facts)
            #expect(response.status == .badRequest)
            let unchanged = try #require(try await Study.find(study.requireId(), on: app.db))
            #expect(unchanged.draftRevision == study.draftRevision)
        }
    }

    @Test
    func eachAdmittedLanguageNeedsAnApprovalOfTheExactResource() async throws {
        try await Self.withApp { app, token in
            let (study, component) = try await Self.bilingualStudy(app: app, token: token, administration: .init(languages: ["en-US", "de"]))
            let detail = try await Self.questionnaire(study, component, app: app, token: token)
            #expect(detail.administrationLanguages == ["en-US", "de"] && detail.languageApprovals.isEmpty)

            var report = try await Self.validate(study, app: app, token: token)
            #expect(report.status == .invalid)
            #expect(Set(report.blockers.filter { $0.rule == "language-approval-missing" }.compactMap(\.language)) == ["en-US", "de"])
            #expect(report.blockers.allSatisfy { $0.componentId == component.uuidString })

            // A single approval leaves the other admitted language blocked.
            let english = try await app.approveLanguage(study, component, sha256: detail.sha256, language: "en-US", token: token)
            #expect(english.status == .created)
            report = try await Self.validate(study, app: app, token: token)
            #expect(report.blockers.map(\.language) == ["de"])
            let languages = try #require(report.questionnaires.first?.administrationLanguages)
            #expect(languages.map(\.language) == ["en-US", "de"] && languages.map(\.approved) == [true, false])
            #expect(languages.allSatisfy { $0.translationComplete })

            #expect(try await app.approveLanguage(study, component, sha256: detail.sha256, language: "de", token: token).status == .created)
            report = try await Self.validate(study, app: app, token: token)
            #expect(report.status == .valid && report.blockers.isEmpty)
            let candidate = try #require(report.candidate)
            let published = try await Self.publish(study, revision: report.draftRevision, candidate: candidate.id, app: app, token: token)
            #expect(published.status == .created)
            let publication = try published.content.decode(Components.Schemas.PublishedStudyResponse.self)
            try await Self.expectPublicationEvidence(publication, component: component, sha256: detail.sha256, app: app)

            let actions = try await Self.auditActions(app: app)
            #expect(actions.filter { $0 == AuditEvent.Action.studyLanguageApproved.rawValue }.count == 2)
        }
    }

    @Test
    func aSingleLanguageStudyNeedsNoTranslationApproval() async throws {
        try await Self.withApp { app, token in
            let (study, component) = try await Self.bilingualStudy(app: app, token: token)
            let detail = try await Self.questionnaire(study, component, app: app, token: token)
            #expect(detail.administrationLanguages == ["en-US"])
            #expect(try await app.approveLanguage(study, component, sha256: detail.sha256, language: "en-US", token: token).status == .created)
            let report = try await Self.validate(study, app: app, token: token)
            #expect(report.status == .valid && report.candidate != nil)
            #expect(report.questionnaires.first?.administrationLanguages.map(\.language) == ["en-US"])
        }
    }

    @Test
    func missingTranslationsAndUnknownLanguagesBlockTheAffectedLanguage() async throws {
        try await Self.withApp { app, token in
            let (study, component) = try await Self.bilingualStudy(
                app: app, token: token, administration: .init(languages: ["en-US", "de", "fr"]), removingItemTranslation: true
            )
            let detail = try await Self.questionnaire(study, component, app: app, token: token)
            for language in ["en-US", "de"] {
                #expect(try await app.approveLanguage(study, component, sha256: detail.sha256, language: language, token: token).status == .created)
            }
            // French is not a language of the resource, so it cannot be approved either.
            let french = try await app.approveLanguage(study, component, sha256: detail.sha256, language: "fr", token: token)
            #expect(french.status == .unprocessableEntity)
            let report = try await Self.validate(study, app: app, token: token)
            #expect(report.status == .invalid)
            let missing = report.blockers.filter { $0.rule == "translation-missing" }
            #expect(missing.map(\.path) == ["Questionnaire.item[0].text"] && missing.allSatisfy { $0.language == "de" })
            #expect(report.blockers.contains { $0.rule == "administration-language-unknown" && $0.language == "fr" })
            let languages = try #require(report.questionnaires.first?.administrationLanguages)
            #expect(languages.map(\.translationComplete) == [true, false, false])
        }
    }

    @Test
    func editsInvalidateApprovalsAndStaleDigestsCannotBeApproved() async throws {
        try await Self.withApp { app, token in
            let (study, component) = try await Self.bilingualStudy(app: app, token: token)
            let original = try await Self.questionnaire(study, component, app: app, token: token)
            #expect(try await app.approveLanguage(study, component, sha256: original.sha256, language: "en-US", token: token).status == .created)
            // A repeated approval returns the one in force.
            let repeated = try await app.approveLanguage(study, component, sha256: original.sha256, language: "en-US", token: token)
            #expect(repeated.status == .ok)
            #expect(try await QuestionnaireLanguageApproval.query(on: app.db).count() == 1)

            let edited = try await Self.replaceQuestionnaire(study, component, app: app, token: token) { $0["title"] = "Weekly check-in" }
            #expect(edited.sha256 != original.sha256 && edited.languageApprovals.isEmpty)
            let report = try await Self.validate(study, app: app, token: token)
            #expect(report.blockers.contains { $0.rule == "language-approval-missing" && $0.language == "en-US" })
            let stale = try await app.approveLanguage(study, component, sha256: original.sha256, language: "en-US", token: token)
            #expect(stale.status == .conflict)
            #expect(try await QuestionnaireLanguageApproval.query(on: app.db).count() == 1)
        }
    }

    @Test
    func approvalRequiresCompleteRevocationEvidence() async throws {
        try await Self.withApp { app, token in
            let (study, component) = try await Self.bilingualStudy(app: app, token: token)
            let detail = try await Self.questionnaire(study, component, app: app, token: token)
            let created = try await app.approveLanguage(study, component, sha256: detail.sha256, language: "de", token: token)
            try #require(created.status == .created)
            let approval = try created.content.decode(Components.Schemas.QuestionnaireLanguageApproval.self)
            let id = try #require(UUID(uuidString: approval.id))
            let row = try #require(try await QuestionnaireLanguageApproval.find(id, on: app.db))
            row.revokedAt = Date()
            await #expect(throws: (any Error).self) { try await row.update(on: app.db) }
            let stored = try #require(try await QuestionnaireLanguageApproval.find(id, on: app.db))
            #expect(stored.revokedAt == nil)
        }
    }

    @Test
    func revokingAnApprovalAfterValidationPreventsPublication() async throws {
        try await Self.withApp { app, token in
            let (study, component) = try await Self.bilingualStudy(app: app, token: token)
            let detail = try await Self.questionnaire(study, component, app: app, token: token)
            let created = try await app.approveLanguage(study, component, sha256: detail.sha256, language: "en-US", token: token)
            let approval = try created.content.decode(Components.Schemas.QuestionnaireLanguageApproval.self)
            let report = try await Self.validate(study, app: app, token: token)
            let candidate = try #require(report.candidate)

            let revoked = try await app.sendRequest(
                .POST,
                "\(apiBasePath)/studies/\(study)/components/\(component)/language-approvals/\(approval.id)/revoke",
                beforeRequest: { request in request.bearerAuth(token) }
            )
            #expect(revoked.status == .ok)
            #expect(try revoked.content.decode(Components.Schemas.QuestionnaireLanguageApproval.self).revokedAt != nil)
            let published = try await Self.publish(study, revision: report.draftRevision, candidate: candidate.id, app: app, token: token)
            #expect(published.status == .conflict)
            #expect(try await PublishedStudy.query(on: app.db).count() == 0)
            let row = try #require(try await QuestionnaireLanguageApproval.find(UUID(uuidString: approval.id), on: app.db))
            row.language = "de"
            await #expect(throws: (any Error).self) { try await row.update(on: app.db) }
            #expect(try await Self.auditActions(app: app).contains(AuditEvent.Action.studyLanguageApprovalRevoked.rawValue))
        }
    }

    @Test
    func researchersWithoutAdministratorAuthorityCannotApprove() async throws {
        let authority = GrantorAuthorityProvider { actor in
            .init(issuer: actor.issuer, subject: actor.subject, enabled: true, roles: [TestApp.researcherRole], groups: ["/Test Group/researcher"])
        }
        try await TestApp.withApp(
            token: .researcher(groups: ["/Test Group/researcher"]), validator: QuestionnaireWorkerReply.validator(), grantorAuthority: authority
        ) { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let component = Component(
                studyId: try study.requireId(), data: .questionnaire(try Self.germanFixture().content()), name: "Café"
            )
            try await component.create(on: app.db)
            let digest = FHIRValidationClient.digest(try Self.germanFixture().bytes())
            let response = try await app.approveLanguage(
                study.requireId(), component.requireId(), sha256: digest, language: "en-US", token: token
            )
            #expect(response.status == .forbidden)
            #expect(try await QuestionnaireLanguageApproval.query(on: app.db).count() == 0)
        }
    }
}


/// Collection routes: required unavailable routes block publication, optional ones are published as unavailable.
extension PublicationReadinessTests {
    @Test
    func optionalProviderDraftRequiresAnExactSource() async throws {
        try await Self.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let id = try study.requireId()
            for identifier in [nil, "", String(repeating: "x", count: 257)] as [String?] {
                var requirement = Self.unregisteredProviderRequirement
                requirement.requirement = .optional
                requirement.sourceTypeIdentifier = identifier
                let patch = Components.Schemas.StudyPatchInput(collectionRequirements: [requirement])
                let response = try await app.sendRequest(.PATCH, "\(apiBasePath)/studies/\(id)", beforeRequest: { request in
                    request.bearerAuth(token)
                    request.headers.replaceOrAdd(name: "If-Match", value: "\"\(study.draftRevision)\"")
                    try request.encodeJSONBody(patch)
                })
                #expect(response.status == .badRequest)
                let stored = try #require(try await Study.find(id, on: app.db))
                #expect(stored.draftRevision == study.draftRevision)
            }
        }
    }

    @Test
    func requiredUnavailableRoutesBlockAndOptionalOnesArePublishedAsUnavailable() async throws {
        try await Self.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let heartRate = CollectionObservationProfile.heartRate.rawValue
            let available = Components.Schemas.CollectionRequirement(profile: heartRate, sourceKind: .participantApp)
            let unsupported = Self.unsupportedNativeRequirement
            let provider = Self.unregisteredProviderRequirement
            let studyID = try study.requireId()
            var revision = try await Self.patchRequirements(
                studyID, revision: study.draftRevision, [available, unsupported, provider], app: app, token: token
            )
            var report = try await Self.validate(studyID, app: app, token: token)
            #expect(report.status == .invalid)
            #expect(report.routes.map(\.availability) == [.available, .unavailable, .unavailable])
            #expect(report.routes.map(\.requirement) == [.required, .required, .required])
            let unavailable = report.blockers.filter { $0.rule == "route-unavailable" }
            #expect(unavailable.map(\.path) == ["collectionRequirements[1]", "collectionRequirements[2]"])

            var optionalUnsupported = unsupported
            optionalUnsupported.requirement = .optional
            var optionalProvider = provider
            optionalProvider.requirement = .optional
            revision = try await Self.patchRequirements(
                studyID, revision: revision, [available, optionalUnsupported, optionalProvider], app: app, token: token
            )
            report = try await Self.validate(studyID, app: app, token: token)
            #expect(report.status == .valid && report.blockers.isEmpty)
            #expect(report.advisories.filter { $0.rule == "route-optional-unavailable" }.count == 2)
            let candidate = try #require(report.candidate)
            let response = try await Self.publish(studyID, revision: revision, candidate: candidate.id, app: app, token: token)
            #expect(response.status == .created)
            let publication = try response.content.decode(Components.Schemas.PublishedStudyResponse.self)
            #expect(publication.unavailableCollectionRequirements == [optionalUnsupported, optionalProvider])
            let stored = try #require(try await PublishedStudy.find(UUID(uuidString: publication.id), on: app.db))
            #expect(stored.collectionPolicy.schemaVersion == PublishedCollectionPolicy.currentSchemaVersion)
            #expect(try stored.collectionPolicy.validatedRequirements(studyID: studyID, revision: 1).map(\.profile) == [heartRate])
            #expect(stored.collectionPolicy.unavailableRequirements.map(\.requirement) == [.optional, .optional])
        }
    }
}
