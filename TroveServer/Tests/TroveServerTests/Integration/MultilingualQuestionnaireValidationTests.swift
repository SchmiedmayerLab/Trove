//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


/// The pinned official validator checks the Grove Questionnaire profile, including `qg-translation-1`.
/// Trove does not repeat those rules; this lane shows that multilingual resources pass and violations fail through it.
struct MultilingualQuestionnaireValidationTests {
    private static var authority: GrantorAuthorityProvider {
        .init { actor in
            .init(issuer: actor.issuer, subject: actor.subject, enabled: true, roles: [TestApp.researcherRole], groups: ["/Test Group/admin"])
        }
    }

    /// The German fixture with its title's translation edited by `change`.
    private static func germanFixture(changingTitleTranslations change: (inout [[String: Any]]) -> Void) throws -> Data {
        let fixture = try #require(try MultilingualQuestionnaireFixture.all().first { $0.translationLanguage == "de" })
        var resource = try #require(try JSONSerialization.jsonObject(with: fixture.bytes()) as? [String: Any])
        var title = try #require(resource["_title"] as? [String: Any])
        var translations = try #require(title["extension"] as? [[String: Any]])
        change(&translations)
        title["extension"] = translations
        resource["_title"] = title
        return try JSONSerialization.data(withJSONObject: resource)
    }

    /// The validator accepts the unchanged fixture and rejects both `qg-translation-1` violations, a translation into
    /// the base language and a second translation into one language, naming the invariant in an error finding.
    private static func expectTranslationViolationsFail(validator: FHIRValidationClient) async throws {
        let fixture = try #require(try MultilingualQuestionnaireFixture.all().first { $0.translationLanguage == "de" })
        let accepted = try await validator.validateQuestionnaire(fixture.bytes())
        #expect(accepted.status == .valid, "\(accepted.diagnostics)")
        #expect(!accepted.diagnostics.contains { $0.severity == .error })
        let violations = [
            try germanFixture { translations in
                var parts = translations[0]["extension"] as? [[String: Any]] ?? []
                parts[0]["valueCode"] = "en-US"
                translations[0]["extension"] = parts
            },
            try germanFixture { translations in
                translations.append(translations[0])
            }
        ]
        for bytes in violations {
            let result = try await validator.validateQuestionnaire(bytes)
            #expect(result.status == .invalid)
            #expect(result.diagnostics.contains {
                $0.severity == .error && $0.source == .fhir && ($0.rule + $0.message).contains("qg-translation-1")
                    && $0.path.hasPrefix("Questionnaire")
            }, "\(result.diagnostics)")
        }
    }

    /// The component operation returns the same findings for a stored resource, without staging anything.
    private static func expectComponentValidationReportsTheInvariant(app: Application, study: Study, token: String?) async throws {
        let component = Component(
            studyId: try study.requireId(),
            data: .questionnaire(.init(questionnaire: String(decoding: try germanFixture { $0.append($0[0]) }, as: UTF8.self))),
            name: "Conflicting translations"
        )
        try await component.create(on: app.db)
        let validation = try await app.sendRequest(
            .POST,
            "\(apiBasePath)/studies/\(study.requireId())/components/\(component.requireId())/validations",
            beforeRequest: { request in request.bearerAuth(token) }
        )
        try #require(validation.status == .ok)
        let result = try validation.content.decode(Components.Schemas.QuestionnaireValidation.self)
        #expect(result.status == .invalid)
        #expect(result.validatorIdentity == Environment.get("FHIR_VALIDATOR_IDENTITY"))
        #expect(result.diagnostics.contains { ($0.rule + $0.message).contains("qg-translation-1") })
    }

    @Test(.enabled(if: Environment.get("TROVE_TEST_VALIDATOR_ASSETS") != nil, "Requires the isolated pinned full validator"))
    func fullValidatorAcceptsBilingualQuestionnairesAndRejectsConflictingTranslations() async throws {
        try #require(Environment.get("FHIR_VALIDATOR_URL") != nil && Environment.get("FHIR_VALIDATOR_IDENTITY") != nil)
        let fixtures = try MultilingualQuestionnaireFixture.all()
        try await TestApp.withApp(grantorAuthority: Self.authority) { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            var components: [UUID: MultilingualQuestionnaireFixture] = [:]
            for fixture in fixtures {
                let component = Component(studyId: try study.requireId(), data: .questionnaire(try fixture.content()), name: fixture.file)
                try await component.create(on: app.db)
                components[try component.requireId()] = fixture
            }
            try await StudyFixtures.approveAdministrationLanguages(studyID: study.requireId(), on: app.db)

            let response = try await app.sendRequest(.POST, "\(apiBasePath)/studies/\(study.requireId())/draft/validations", beforeRequest: { request in
                request.bearerAuth(token)
                request.headers.replaceOrAdd(name: "If-Match", value: "\"\(study.draftRevision)\"")
            })
            try #require(response.status == .created, "\(response.status) \(response.body.string)")
            let report = try response.content.decode(Components.Schemas.StudyDraftValidation.self)
            #expect(report.status == .valid && report.candidate != nil && report.blockers.isEmpty)
            #expect(report.questionnaires.count == fixtures.count)
            for evidence in report.questionnaires {
                let componentId = try #require(UUID(uuidString: evidence.componentId))
                let fixture = try #require(components[componentId])
                #expect(evidence.sha256 == ArtifactStore.digest(try fixture.bytes()))
                #expect(evidence.language == fixture.language)
                #expect(evidence.translationLanguages == fixture.translationLanguages)
            }

            try await Self.expectTranslationViolationsFail(validator: FHIRValidationClient(application: app))

            try await Self.expectComponentValidationReportsTheInvariant(app: app, study: study, token: token)
        }
    }
}
