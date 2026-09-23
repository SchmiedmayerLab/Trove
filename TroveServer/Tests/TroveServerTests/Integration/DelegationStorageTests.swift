//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import SQLKit
import Testing
@testable import TroveServer
import VaporTesting


struct DelegationStorageTests {
    @Test(arguments: [false, true])
    func mandatoryAuditFailureRollsBackGrantChanges(revoking: Bool) async throws {
        try await TestApp.withApp { app, _ in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let studyID = try study.requireId()
            let owner = context(subject: "owner", admin: true)
            let service = app.grove[DelegationService.self]
            let grant = try await AuthContext.$current.withValue(owner) { try await create(service: service, studyID: studyID) }
            let sql = try #require(app.db as? any SQLDatabase)
            // This database belongs solely to this test. Break the mandatory sink, not its checks.
            try await sql.raw("DROP TABLE audit_events").run()
            await #expect(throws: (any Error).self) {
                try await AuthContext.$current.withValue(owner) {
                    if revoking {
                        _ = try await service.revoke(studyID: studyID, delegationID: grant.id)
                    } else {
                        _ = try await create(service: service, studyID: studyID)
                    }
                }
            }
            let repository = app.grove[StudyRepository.self]
            try await app.db.transaction { transaction in
                _ = try await repository.lockStudy(id: studyID, on: transaction)
                let page = try await DelegationRepository.list(studyID: studyID, owner: nil, before: nil, limit: 100, on: transaction)
                #expect(page.grants.count == 1)
                #expect(page.grants.first?.id == grant.id)
                #expect(page.grants.first?.revokedAt == nil)
            }
        }
    }

    @Test
    func paginationScopesCursorsToVisibleGrants() async throws {
        try await TestApp.withApp { app, _ in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let studyID = try study.requireId()
            let service = app.grove[DelegationService.self]
            let owner = context(subject: "owner", admin: false)
            let other = context(subject: "other", admin: false)
            let first = try await AuthContext.$current.withValue(owner) { try await create(service: service, studyID: studyID) }
            let second = try await AuthContext.$current.withValue(owner) { try await create(service: service, studyID: studyID) }
            let hidden = try await AuthContext.$current.withValue(other) { try await create(service: service, studyID: studyID) }
            let page = try await AuthContext.$current.withValue(owner) { try await service.list(studyID: studyID, limit: 1) }
            #expect(page.grants.count == 1)
            #expect(page.grants.first?.id == second.id)
            #expect(page.nextBefore == second.id)
            let last = try await AuthContext.$current.withValue(owner) {
                try await service.list(studyID: studyID, before: page.nextBefore, limit: 1)
            }
            #expect(last.grants.map(\.id) == [first.id])
            #expect(last.nextBefore == nil)
            await #expect(throws: ServerError.self) {
                try await AuthContext.$current.withValue(owner) { try await service.list(studyID: studyID, before: hidden.id) }
            }
            let all = try await AuthContext.$current.withValue(context(subject: "administrator", admin: true)) {
                try await service.list(studyID: studyID)
            }
            #expect(Set(all.grants.map(\.id)) == [first.id, second.id, hidden.id])
        }
    }

    @Test
    func concurrentRevocationAndApplyHaveOneAuthoritativeOrder() async throws {
        let app = try await TestApp.makeApplication()
        do {
            _ = try await TestApp.configureTesting(app, grantorAuthority: .init { actor in
                .init(
                    issuer: actor.issuer,
                    subject: actor.subject,
                    enabled: true,
                    roles: [TestApp.researcherRole],
                    groups: ["/Test Group/admin"]
                )
            })
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let studyID = try study.requireId()
            let owner = context(subject: "owner", admin: true)
            let service = app.grove[DelegationService.self]
            let grant = try await AuthContext.$current.withValue(owner) { try await create(service: service, studyID: studyID) }
            async let applied = applyDelegatedChange(app: app, grant: grant, revision: study.draftRevision)
            async let revoked = AuthContext.$current.withValue(owner) { try await service.revoke(studyID: studyID, delegationID: grant.id) }
            let (didApply, receipt) = try await (applied, revoked)
            #expect(receipt.revokedAt != nil)
            let stored = try #require(try await app.grove[StudyRepository.self].find(id: studyID))
            #expect(stored.icon == (didApply ? "concurrent-edit" : study.icon))
            let sql = try #require(app.db as? any SQLDatabase)
            let edits = try await sql.raw("""
                SELECT occurred_at FROM audit_events WHERE study_id = \(bind: studyID) AND action = 'study.draft.edited'
                """)
                .all()
            #expect(edits.count == (didApply ? 1 : 0))
            if let edit = edits.first, let revokedAt = receipt.revokedAt {
                #expect(try edit.decode(column: "occurred_at", as: Date.self) <= revokedAt)
            }
            #expect(try await !applyDelegatedChange(app: app, grant: grant, revision: stored.draftRevision))
            try await TestDatabase.shutdown(app)
        } catch {
            try? await TestDatabase.shutdown(app)
            throw error
        }
    }

    /// The two real database transactions race. SQLite serializes writers; the optional
    /// PostgreSQL lane uses two independent leases and exercises the study-row lock.
    private func applyDelegatedChange(app: Application, grant: DelegationGrant, revision: UUID) async throws -> Bool {
        let actor = AuthContext(
            issuer: TestApp.issuer,
            subject: grant.grantor.subject,
            email: "researcher@example.test",
            roles: [TestApp.researcherRole],
            groups: ["/Test Group/admin"],
            researcherRole: TestApp.researcherRole,
            participantRole: TestApp.participantRole,
            executingClientID: "trove-draft-editor",
            clientAccess: .delegatedDraft,
            delegationID: grant.id
        )
        do {
            _ = try await AuthContext.$current.withValue(actor) {
                try await app.grove[StudyService.self].patchStudy(
                    id: grant.studyID,
                    expectedRevision: revision,
                    patch: .init(icon: "concurrent-edit")
                )
            }
            return true
        } catch let error as ServerError where error.status == .forbidden {
            return false
        }
    }

    private func create(service: DelegationService, studyID: UUID) async throws -> DelegationGrant {
        try await service.create(
            studyID: studyID,
            clientID: "trove-draft-editor",
            preset: .editStudyDraft,
            expiresAt: Date().addingTimeInterval(300)
        )
    }

    private func context(subject: String, admin: Bool) -> AuthContext {
        .init(
            issuer: TestApp.issuer,
            subject: subject,
            email: "researcher@example.test",
            roles: [TestApp.researcherRole],
            groups: [admin ? "/Test Group/admin" : "/Test Group/researcher"],
            researcherRole: TestApp.researcherRole,
            participantRole: TestApp.participantRole,
            executingClientID: "trove-cli"
        )
    }
}
