//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import JWTKit
import Testing
@testable import TroveServer
import VaporTesting


struct DelegationAuthorizationTests {
    enum Denial: CaseIterable, Sendable {
        case expired, revoked, wrongClient, wrongStudy, wrongSubject, disabled, removedRole, removedGroup, unavailable
    }

    private var validAuthority: GrantorAuthorityProvider {
        .init { actor in
            .init(
                issuer: actor.issuer,
                subject: actor.subject,
                enabled: true,
                roles: [TestApp.researcherRole],
                groups: ["/Test Group/admin"]
            )
        }
    }

    @Test(arguments: [nil, "unregistered-client", "trove-dev-cli"] as [String?])
    func missingUnknownAndDevelopmentClientsAreRejected(clientID: String?) async throws {
        try await TestApp.withApp(token: .none) { app, _ in
            let keys = JWTKeyCollection()
            await keys.add(hmac: HMACKey(from: TestApp.testSecret), digestAlgorithm: .sha256, kid: "test-key")
            let token = try await TestApp.signToken(keys: keys, roles: [TestApp.researcherRole], groups: [], clientID: clientID)
            try await app.test(.GET, "\(apiBasePath)/groups", beforeRequest: { request in
                request.bearerAuth(token)
            }) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func delegatedClientCannotEscapeThroughRoleClaimsOrOmittingGrant() async throws {
        try await TestApp.withApp(token: .none) { app, _ in
            let keys = JWTKeyCollection()
            await keys.add(hmac: HMACKey(from: TestApp.testSecret), digestAlgorithm: .sha256, kid: "test-key")
            let token = try await TestApp.signToken(
                keys: keys,
                roles: [TestApp.researcherRole, TestApp.participantRole],
                groups: ["/Test Group/admin"],
                clientID: "trove-draft-editor"
            )
            let studyID = UUID()
            let paths: [(HTTPMethod, String)] = [
                (.GET, "/groups"), (.GET, "/participant/profile"), (.GET, "/studies/\(studyID)/enrollments"),
                (.GET, "/studies/\(studyID)/audit-events"), (.GET, "/studies/\(studyID)/published"),
                (.GET, "/studies/\(studyID)/invitation-codes"), (.POST, "/studies/\(studyID)/publish"),
                (.GET, "/studies/\(studyID)/delegations"), (.POST, "/studies/\(studyID)/delegations"),
                (.POST, "/studies/\(studyID)/delegations/\(UUID())/revoke"),
                (.DELETE, "/studies/\(studyID)")
            ]
            for (method, path) in paths {
                for includeGrant in [false, true] {
                    try await app.test(method, apiBasePath + path, beforeRequest: { request in
                        request.bearerAuth(token)
                        if includeGrant { request.headers.replaceOrAdd(name: "Trove-Delegation-ID", value: UUID().uuidString) }
                    }) { response in
                        #expect(response.status == .forbidden)
                    }
                }
            }
            try await app.test(.GET, "\(apiBasePath)/studies/\(studyID)", beforeRequest: { request in
                request.bearerAuth(token)
            }) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    @Test
    func persistedRevocationInvalidatesAlreadyPreparedAccess() async throws {
        let app = try await TestApp.makeApplication()
        do {
            let keys = try await TestApp.configureTesting(app, grantorAuthority: validAuthority)
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let studyID = try study.requireId()
            let owner = context(clientAccess: .interactive)
            let service = app.grove[DelegationService.self]
            let authorization = app.grove[AuthorizationService.self]
            let repository = app.grove[StudyRepository.self]
            let grant = try await AuthContext.$current.withValue(owner) {
                try await service.create(
                    studyID: studyID,
                    clientID: "trove-draft-editor",
                    preset: .editStudyDraft,
                    expiresAt: Date().addingTimeInterval(300)
                )
            }
            try await expectDelegatedHTTPReadAndEdit(app: app, keys: keys, grant: grant, revision: study.draftRevision)
            let delegated = context(clientAccess: .delegatedDraft, delegationID: grant.id)
            let prepared = try await AuthContext.$current.withValue(delegated) {
                try await authorization.prepareDraftAccess(operation: .edit)
            }
            try await app.db.transaction { transaction in
                let locked = try await repository.lockStudy(id: studyID, on: transaction)
                let audit = try await authorization.authorizeDraft(prepared, study: locked, on: transaction)
                #expect(audit.delegationID == grant.id)
                #expect(audit.initiator?.subject == owner.subject)
            }
            let revoked = try await AuthContext.$current.withValue(owner) {
                try await service.revoke(studyID: studyID, delegationID: grant.id)
            }
            #expect(revoked.revokedAt != nil)
            await #expect(throws: ServerError.self) {
                try await app.db.transaction { transaction in
                    let locked = try await repository.lockStudy(id: studyID, on: transaction)
                    _ = try await authorization.authorizeDraft(prepared, study: locked, on: transaction)
                }
            }
            let repeated = try await AuthContext.$current.withValue(owner) {
                try await service.revoke(studyID: studyID, delegationID: grant.id)
            }
            #expect(repeated.revokedAt == revoked.revokedAt)
            try await expectRevokedHTTPAccessDenied(app: app, keys: keys, grant: grant)
            try await TestDatabase.shutdown(app)
        } catch {
            try? await TestDatabase.shutdown(app)
            throw error
        }
    }

    @Test(arguments: Denial.allCases)
    func invalidGrantOrCurrentAuthorityCannotChangeStudy(denial: Denial) async throws {
        let app = try await TestApp.makeApplication()
        do {
            _ = try await TestApp.configureTesting(app, grantorAuthority: .init { actor in
                if denial == .unavailable { throw ServerError.forbidden }
                return .init(
                    issuer: actor.issuer,
                    subject: actor.subject,
                    enabled: denial != .disabled,
                    roles: denial == .removedRole ? [] : [TestApp.researcherRole],
                    groups: denial == .removedGroup ? [] : ["/Test Group/admin"]
                )
            })
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let other = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let grant = DelegationGrant(
                id: UUID(),
                studyID: try study.requireId(),
                grantor: context(clientAccess: .interactive).auditContext.actor,
                clientID: "trove-draft-editor",
                preset: .editStudyDraft,
                createdAt: Date().addingTimeInterval(-120),
                expiresAt: Date().addingTimeInterval(denial == .expired ? -60 : 300),
                revokedAt: denial == .revoked ? Date().addingTimeInterval(-30) : nil
            )
            let repository = app.grove[StudyRepository.self]
            try await app.db.transaction { transaction in
                _ = try await repository.lockStudy(id: study.requireId(), on: transaction)
                try await DelegationRepository.create(grant, on: transaction)
                if let revokedAt = grant.revokedAt {
                    _ = try await DelegationRepository.revoke(grant, at: revokedAt, on: transaction)
                }
            }
            let actor = context(
                clientAccess: .delegatedDraft,
                delegationID: grant.id,
                subject: denial == .wrongSubject ? "someone-else" : "grantor",
                clientID: denial == .wrongClient ? "another-client" : "trove-draft-editor"
            )
            let target = denial == .wrongStudy ? other : study
            try await expectMutationDenied(app: app, context: actor, study: target)
            let unchanged = try #require(try await repository.find(id: target.requireId()))
            #expect(unchanged.icon == target.icon)
            #expect(unchanged.draftRevision == target.draftRevision)
            try await TestDatabase.shutdown(app)
        } catch {
            try? await TestDatabase.shutdown(app)
            throw error
        }
    }

    private func expectMutationDenied(app: Application, context: AuthContext, study: Study) async throws {
        let authorization = app.grove[AuthorizationService.self]
        let repository = app.grove[StudyRepository.self]
        await #expect(throws: ServerError.self) {
            try await AuthContext.$current.withValue(context) {
                let access = try await authorization.prepareDraftAccess(operation: .edit)
                try await app.db.transaction { transaction in
                    let locked = try await repository.lockStudy(id: study.requireId(), on: transaction)
                    _ = try await authorization.authorizeDraft(access, study: locked, on: transaction)
                    locked.icon = "forbidden-change"
                    try await repository.advanceDraftRevision(locked, on: transaction)
                }
            }
        }
    }

    private func expectDelegatedHTTPReadAndEdit(app: Application, keys: JWTKeyCollection, grant: DelegationGrant, revision: UUID) async throws {
        let token = try await TestApp.signToken(
            keys: keys,
            subject: grant.grantor.subject,
            roles: [TestApp.researcherRole, TestApp.participantRole],
            groups: ["/Test Group/admin"],
            clientID: "trove-draft-editor"
        )
        try await app.test(.GET, "\(apiBasePath)/studies/\(grant.studyID)", beforeRequest: { request in
            request.bearerAuth(token)
            request.headers.replaceOrAdd(name: "Trove-Delegation-ID", value: grant.id.uuidString)
        }) { response in
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == ["no-store"])
        }
        try await app.test(.PATCH, "\(apiBasePath)/studies/\(grant.studyID)", beforeRequest: { request in
            request.bearerAuth(token)
            request.headers.replaceOrAdd(name: "Trove-Delegation-ID", value: grant.id.uuidString)
            request.headers.replaceOrAdd(name: "If-Match", value: "\"\(revision.uuidString)\"")
            request.headers.contentType = .json
            request.body = .init(string: "{\"icon\":\"delegated-edit\"}")
        }) { response in
            #expect(response.status == .ok)
        }
        let stored = try #require(try await app.grove[StudyRepository.self].find(id: grant.studyID))
        #expect(stored.icon == "delegated-edit")
        #expect(stored.draftRevision != revision)
    }

    private func expectRevokedHTTPAccessDenied(app: Application, keys: JWTKeyCollection, grant: DelegationGrant) async throws {
        let token = try await TestApp.signToken(
            keys: keys,
            subject: grant.grantor.subject,
            roles: [TestApp.researcherRole, TestApp.participantRole],
            groups: ["/Test Group/admin"],
            clientID: "trove-draft-editor"
        )
        try await app.test(.GET, "\(apiBasePath)/studies/\(grant.studyID)", beforeRequest: { request in
            request.bearerAuth(token)
            request.headers.replaceOrAdd(name: "Trove-Delegation-ID", value: grant.id.uuidString)
        }) { response in
            #expect(response.status == .forbidden)
        }
    }

    private func context(
        clientAccess: KeycloakClientPolicy.Access,
        delegationID: UUID? = nil,
        subject: String = "grantor",
        clientID: String? = nil
    ) -> AuthContext {
        .init(
            issuer: TestApp.issuer,
            subject: subject,
            email: "grantor@example.test",
            roles: [TestApp.researcherRole],
            groups: ["/Test Group/admin"],
            researcherRole: TestApp.researcherRole,
            participantRole: TestApp.participantRole,
            executingClientID: clientID ?? (clientAccess == .interactive ? "trove-cli" : "trove-draft-editor"),
            clientAccess: clientAccess,
            delegationID: delegationID
        )
    }
}
