//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import FluentPostgresDriver
import Foundation
import SQLKit
import Testing
@testable import TroveServer
import VaporTesting


struct TaskClosureTests {
    @Test
    func unchangedCheckpointOnLongLivedEnrollment() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let id = fixture.enrollmentIDs[0]
            let publications = PublishedStudy.query(on: app.db).filter(\.$study.$id == fixture.studyIDs[0])
            let publication = try #require(try await publications.first())
            let sql = try #require(app.db as? any SQLDatabase)
            let postgres = app.db is any PostgresDatabase
            try await Self.seedHistory(on: sql, postgres: postgres, enrollmentID: id, publicationID: publication.requireID())
            if !postgres {
                let now = Date()
                let query = TaskOccurrenceStore.assignmentWindow(enrollmentID: id, from: now, until: now.addingTimeInterval(14 * 86_400))
                let plan = try await sql.raw("EXPLAIN QUERY PLAN \(query)").all()
                let details = try plan.map { try $0.decode(column: "detail", as: String.self) }
                #expect(details.contains { $0.contains("task_assignment_window") && $0.contains("due_at>? AND due_at<?") })
            }
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let service = app.grove[ConsentService.self]
                // A checkpoint retained by a client that already consumed all historical assignments and removals.
                let enrollment = try #require(try await Enrollment.find(id, on: app.db))
                let checkpoint = UUID()
                try await sql.raw("""
                    INSERT INTO task_sync_cursors (id, enrollment_id, participant_id, projection_version, enrollment_version,
                        active, after_version, snapshot, expires_at)
                    VALUES (\(bind: checkpoint), \(bind: id), \(bind: enrollment.$participant.id), \(bind: TaskOccurrenceStore.projectionVersion),
                        \(bind: enrollment.stateVersion), TRUE, 731, FALSE, \(bind: Date().addingTimeInterval(3600)))
                    """)
                    .run()
                let page = try await service.taskPage(enrollmentID: id, cursor: checkpoint, limit: 1)
                #expect(page.items.isEmpty && page.invalidated.isEmpty && page.snapshotVersion == 731)
                #expect(page.nextCursor == nil && page.checkpoint != nil)
            }
        }
    }

    @Test
    func withdrawalPagesAllHistoricalRemovalsWithOneAuditMutation() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let enrollmentID = fixture.enrollmentIDs[0]
            let studyID = fixture.studyIDs[0]
            let publications = PublishedStudy.query(on: app.db).filter(\.$study.$id == studyID)
            let publication = try #require(try await publications.first())
            let publicationID = try publication.requireID()
            let sql = try #require(app.db as? any SQLDatabase)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let service = app.grove[ConsentService.self]
                let empty = try await service.taskPage(enrollmentID: enrollmentID, cursor: nil, limit: 1)
                let start = try #require(empty.checkpoint.flatMap(UUID.init(uuidString:)))
                try await Self.seedHistory(
                    on: sql, postgres: app.db is any PostgresDatabase, enrollmentID: enrollmentID, publicationID: publicationID
                )
                _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: enrollmentID)
                try await Self.checkRemovals(start: start, enrollmentID: enrollmentID, service: service)
                let snapshot = try await service.taskPage(enrollmentID: enrollmentID, cursor: nil, limit: 1)
                #expect(snapshot.items.isEmpty && snapshot.invalidated.isEmpty && snapshot.nextCursor == nil)
                let physical = try await sql.raw("SELECT id FROM task_occurrences WHERE invalidated_version IS NOT NULL").all()
                #expect(physical.count == 1)
                let unstamped = try await sql.raw("SELECT id FROM task_occurrences WHERE invalidated_at IS NULL").all()
                #expect(unstamped.isEmpty)
                let audit = try await sql.raw("""
                    SELECT target_version FROM audit_events WHERE action = 'tasks.invalidated' AND target_id = \(bind: enrollmentID)
                    """)
                    .all()
                #expect(try audit.map { try $0.decode(column: "target_version", as: String.self) } == ["1462/enrollment-closure"])
            }
        }
    }

    @Test
    func failedClosureAuditRollsBackWithdrawal() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let id = fixture.enrollmentIDs[0]
            let publications = PublishedStudy.query(on: app.db).filter(\.$study.$id == fixture.studyIDs[0])
            let publication = try #require(try await publications.first())
            let sql = try #require(app.db as? any SQLDatabase)
            let postgres = app.db is any PostgresDatabase
            try await Self.seedHistory(on: sql, postgres: postgres, enrollmentID: id, publicationID: publication.requireID())
            if postgres {
                try await sql.raw("""
                    CREATE TRIGGER reject_task_closure BEFORE INSERT ON audit_events FOR EACH ROW
                    WHEN (NEW.action = 'tasks.invalidated') EXECUTE FUNCTION trove_reject_audit_mutation()
                    """)
                    .run()
            } else {
                try await sql.raw("""
                    CREATE TRIGGER reject_task_closure BEFORE INSERT ON audit_events WHEN NEW.action = 'tasks.invalidated'
                    BEGIN SELECT RAISE(ABORT, 'Synthetic closure audit failure'); END
                    """)
                    .run()
            }
            await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                await #expect(throws: (any Error).self) {
                    try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: id)
                }
            }
            let stored = try #require(try await Enrollment.find(id, on: app.db))
            #expect(stored.withdrawnAt == nil && stored.taskClosureBase == nil)
        }
    }
}


extension TaskClosureTests {
    private static func seedHistory(on sql: any SQLDatabase, postgres: Bool, enrollmentID: UUID, publicationID: UUID) async throws {
        let due: SQLQueryString = postgres
            ? "CURRENT_TIMESTAMP - n * INTERVAL '1 day'"
            : "datetime('now', '-' || n || ' days')"
        try await sql.raw("""
            WITH RECURSIVE history(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM history WHERE n < 730)
            INSERT INTO task_occurrences
                (id, enrollment_id, publication_id, due_at, assigned_version, assigned_at, invalidated_version, invalidated_at, projection)
            SELECT 'history-' || n, \(bind: enrollmentID), \(bind: publicationID), \(due), n, \(due),
                CASE WHEN n = 1 THEN 731 ELSE NULL END, CASE WHEN n = 1 THEN \(due) ELSE NULL END, '{}' FROM history
            """)
            .run()
    }

    private static func checkRemovals(start: UUID, enrollmentID: UUID, service: ConsentService) async throws {
        var cursor: UUID? = start
        var ids = [String]()
        repeat {
            let page = try await service.taskPage(enrollmentID: enrollmentID, cursor: cursor, limit: 43)
            #expect(page.items.isEmpty && page.invalidated.count <= 43 && page.snapshotVersion == 1462)
            try #require(!page.invalidated.isEmpty)
            ids.append(contentsOf: page.invalidated)
            cursor = page.nextCursor.flatMap(UUID.init(uuidString:))
            if cursor == nil {
                let checkpoint = try #require(page.checkpoint.flatMap(UUID.init(uuidString:)))
                let subsequent = try await service.taskPage(enrollmentID: enrollmentID, cursor: checkpoint, limit: 43)
                #expect(subsequent.items.isEmpty && subsequent.invalidated.isEmpty)
            }
        } while cursor != nil && ids.count <= 730
        #expect(ids == (1...730).map { "history-\($0)" })
    }
}
