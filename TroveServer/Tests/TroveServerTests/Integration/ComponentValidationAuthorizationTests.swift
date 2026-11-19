//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import TroveServer
import VaporTesting


/// Validating a component runs the validator, so a delegated client needs a grant that includes validation.
struct ComponentValidationAuthorizationTests {
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
            let grant = try await AuthContext.$current.withValue(owner) {
                try await app.grove[DelegationService.self].create(
                    studyID: study.requireId(), clientID: "trove-draft-editor", preset: preset, expiresAt: Date().addingTimeInterval(300)
                )
            }
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
            }
            try await TestDatabase.shutdown(app)
        } catch {
            try? await TestDatabase.shutdown(app)
            throw error
        }
    }
}
