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


/// Validating a component runs the validator, so a delegated client needs a grant that includes validation.
struct ComponentValidationAuthorizationTests {
    private static func grant(_ preset: DelegationPreset, study: Study, app: Application) async throws -> DelegationGrant {
        let owner = AuthContext(
            issuer: TestApp.issuer,
            subject: "grantor",
            email: "grantor@example.test",
            roles: [TestApp.researcherRole],
            groups: ["/Test Group/admin"],
            researcherRole: TestApp.researcherRole,
            participantRole: TestApp.participantRole,
            executingClientID: "trove-cli",
            clientAccess: .interactive,
            delegationID: nil
        )
        return try await AuthContext.$current.withValue(owner) {
            try await app.grove[DelegationService.self].create(
                studyID: study.requireId(), clientID: "trove-draft-editor", preset: preset, expiresAt: Date().addingTimeInterval(300)
            )
        }
    }

    @Test(arguments: [DelegationPreset.inspectStudy, .editStudyDraft])
    func onlyAGrantWithValidationCanValidateAComponent(preset: DelegationPreset) async throws {
        let app = try await TestApp.makeApplication()
        do {
            let keys = try await TestApp.configureTesting(app, grantorAuthority: .init { actor in
                .init(issuer: actor.issuer, subject: actor.subject, enabled: true, roles: [TestApp.researcherRole], groups: ["/Test Group/admin"])
            })
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let component = try await ComponentFixtures.createQuestionnaireComponent(on: app.db, studyId: study.requireId())
            let grant = try await Self.grant(preset, study: study, app: app)
            let token = try await TestApp.signToken(
                keys: keys,
                subject: grant.grantor.subject,
                roles: [TestApp.researcherRole],
                groups: ["/Test Group/admin"],
                clientID: "trove-draft-editor"
            )
            let path = try "\(apiBasePath)/studies/\(study.requireId())/components/\(component.requireId())/validations"
            try await app.test(.POST, path, beforeRequest: { request in
                request.bearerAuth(token)
                request.headers.replaceOrAdd(name: "Trove-Delegation-ID", value: grant.id.uuidString)
            }) { response in
                #expect(response.status == (preset == .editStudyDraft ? .ok : .forbidden))
                guard response.status == .ok else {
                    return
                }
                let result = try response.content.decode(Components.Schemas.QuestionnaireValidation.self)
                guard case .questionnaire(let content) = component.data else {
                    Issue.record("Expected a questionnaire component")
                    return
                }
                if Environment.get("FHIR_VALIDATOR_URL") != nil, let identity = Environment.get("FHIR_VALIDATOR_IDENTITY") {
                    #expect(result.validatorIdentity == identity)
                    #expect(result.status != .unavailable)
                } else {
                    // Without a configured validator nothing establishes validity.
                    #expect(result.status == .unavailable)
                }
                #expect(result.sha256 == FHIRValidationClient.digest(Data(content.questionnaire.utf8)))
                #expect(result.draftRevision == study.draftRevision.uuidString)
                #expect(result.componentId == (try component.requireId()).uuidString)
            }
            // Validating a component changes neither the draft nor the publication candidates.
            let stored = try #require(try await Study.find(study.requireId(), on: app.db))
            #expect(stored.draftRevision == study.draftRevision)
            #expect(try await StudyPublicationCandidate.query(on: app.db).count() == 0)
            try await TestDatabase.shutdown(app)
        } catch {
            try? await TestDatabase.shutdown(app)
            throw error
        }
    }
}
