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


struct PublicationAuthorityTests {
    enum Authority: CaseIterable, Sendable {
        case allowed, disabled, roleRemoved, adminRemoved, wrongSubject, unavailable
    }

    @Test(arguments: Authority.allCases)
    func publicationRequiresCurrentAdministratorAuthority(authority: Authority) async throws {
        let app = try await TestApp.makeApplication()
        do {
            let provider = authority == .unavailable ? GrantorAuthorityProvider.unavailable : .init { actor in
                .init(
                    issuer: actor.issuer,
                    subject: authority == .wrongSubject ? "other-researcher" : actor.subject,
                    enabled: authority != .disabled,
                    roles: authority == .roleRemoved ? [] : [TestApp.researcherRole],
                    groups: [authority == .adminRemoved ? "/Test Group/researcher" : "/Test Group/admin"]
                )
            }
            _ = try await TestApp.configureTesting(app, grantorAuthority: provider)
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            if authority == .allowed {
                try await authorizePublication(app: app, studyID: study.requireId())
            } else {
                await #expect {
                    try await authorizePublication(app: app, studyID: study.requireId())
                } throws: { error in
                    (error as? ServerError)?.status == (authority == .unavailable ? .serviceUnavailable : .forbidden)
                }
            }
            try await TestDatabase.shutdown(app)
        } catch {
            try? await TestDatabase.shutdown(app)
            throw error
        }
    }

    @Test(arguments: [DelegationPreset.inspectStudy, .editStudyDraft])
    func delegationPresetsNeverGrantPublication(preset: DelegationPreset) {
        #expect(!preset.permissions.contains(.publish))
    }

    private func authorizePublication(app: Application, studyID: UUID) async throws {
        let context = AuthContext(
            issuer: TestApp.issuer,
            subject: "publishing-researcher",
            email: "researcher@example.test",
            roles: [TestApp.researcherRole],
            groups: ["/Test Group/admin"],
            researcherRole: TestApp.researcherRole,
            participantRole: TestApp.participantRole,
            executingClientID: "trove-cli"
        )
        try await AuthContext.$current.withValue(context) {
            let authorization = app.grove[AuthorizationService.self]
            let access = try await authorization.prepareDraftAccess(operation: .publish)
            try await app.db.transaction { transaction in
                let study = try await app.grove[StudyRepository.self].lockStudy(id: studyID, on: transaction)
                _ = try await authorization.authorizeDraft(access, study: study, on: transaction)
            }
        }
    }
}
