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
@testable import TroveServer


struct StudyDraftRepositoryTests {
    @Test
    func staleRevisionCannotOverwriteAcceptedChange() async throws {
        try await TestApp.withApp { app, _ in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let initial = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let studyID = try initial.requireId()
            let revision = initial.draftRevision
            let repository = StudyRepository(database: app.db)

            let acceptedRevision = try await app.db.transaction { transaction in
                let draft = try await repository.lockDraft(id: studyID, expectedRevision: revision, on: transaction)
                draft.icon = "accepted"
                try await repository.advanceDraftRevision(draft, on: transaction)
                return draft.draftRevision
            }

            await #expect {
                try await app.db.transaction { transaction in
                    let stale = try await repository.lockDraft(id: studyID, expectedRevision: revision, on: transaction)
                    stale.icon = "stale"
                    try await repository.advanceDraftRevision(stale, on: transaction)
                }
            } throws: { error in
                (error as? ServerError)?.status.code == 412
            }

            let stored = try #require(try await repository.find(id: studyID))
            #expect(stored.icon == "accepted")
            #expect(stored.draftRevision == acceptedRevision)
            #expect(acceptedRevision != revision)
        }
    }

    @Test
    func failedTransactionPreservesContentAndRevision() async throws {
        try await TestApp.withApp { app, _ in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let initial = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let studyID = try initial.requireId()
            let revision = initial.draftRevision
            let repository = StudyRepository(database: app.db)

            await #expect(throws: AuditError.invalidMetadata) {
                try await app.db.transaction { transaction in
                    let draft = try await repository.lockDraft(id: studyID, expectedRevision: revision, on: transaction)
                    draft.icon = "must-not-persist"
                    try await repository.advanceDraftRevision(draft, on: transaction)
                    // The same transaction must roll back if mandatory audit persistence fails.
                    let event = AuditEvent(
                        context: .init(actor: .init(issuer: "", subject: "synthetic-researcher")),
                        action: .studyPublished,
                        scope: .study(studyID: studyID),
                        target: .init(id: studyID)
                    )
                    try await AuditRepository.recordMutation(event, on: transaction)
                }
            }

            let stored = try #require(try await repository.find(id: studyID))
            #expect(stored.icon == initial.icon)
            #expect(stored.draftRevision == revision)
        }
    }

    @Test
    func draftLockRequiresExplicitTransaction() async throws {
        try await TestApp.withApp { app, _ in
            let repository = StudyRepository(database: app.db)
            await #expect(throws: AuditError.transactionRequired) {
                try await repository.lockDraft(id: UUID(), expectedRevision: UUID(), on: app.db)
            }
        }
    }

    @Test
    func acceptedRevisionSurvivesDatabaseRestart() async throws {
        try await TestApp.withApp { app, _ in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let initial = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let studyID = try initial.requireId()
            let revision = initial.draftRevision
            let repository = StudyRepository(database: app.db)
            let acceptedRevision = try await app.db.transaction { transaction in
                let draft = try await repository.lockDraft(id: studyID, expectedRevision: revision, on: transaction)
                draft.icon = "persistent"
                try await repository.advanceDraftRevision(draft, on: transaction)
                return draft.draftRevision
            }

            try await TestDatabase.withRestartedApplication(app) { restarted in
                let restored = try #require(try await Study.find(studyID, on: restarted.db))
                #expect(restored.icon == "persistent")
                #expect(restored.draftRevision == acceptedRevision)
            }
        }
    }
}
