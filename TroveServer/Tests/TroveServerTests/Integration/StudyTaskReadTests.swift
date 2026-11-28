//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import FluentPostgresDriver
import Foundation
import GroveStudyDefinition
import SQLKit
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


struct StudyTaskReadTests {
    private static func assignTasks(_ fixture: ClinicalEventStoreTests.Fixture, on app: Application) async throws -> UUID {
        let schedule = PublishedTaskSchedule(
            schedule: .init(
                id: UUID(),
                componentId: UUID(),
                scheduleDefinition: .repeated(.daily(hour: 12), offset: .init(day: 1)),
                completionPolicy: .sameDayAfterStart,
                notifications: .disabled
            ),
            questionnaireSHA256: String(repeating: "a", count: 64),
            language: "en-US",
            administrationLanguages: ["en-US"],
            questionnaireCanonical: "https://example.test/fhir/Questionnaire/synthetic|1.0.0"
        )
        for (study, enrollment) in zip(fixture.studyIDs, fixture.enrollmentIDs) {
            _ = try await PublishedStudyFixtures.createPublishedStudy(on: app.db, studyId: study, revision: 2, taskSchedules: [schedule])
            _ = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await ClinicalEventStoreTests.acceptConsent(enrollmentID: enrollment, on: app, revision: 2)
            }
        }
        return schedule.schedule.id
    }

    /// Follows every continuation after `after` and returns its items and page count.
    private static func continuation(path: String, after: String, bearer: String?, on app: Application) async throws
        -> (items: [Components.Schemas.ParticipantTaskOccurrence], pages: Int) {
        var items: [Components.Schemas.ParticipantTaskOccurrence] = []
        var cursor: String? = after
        var pages = 0
        while let current = cursor {
            pages += 1
            let continuation = try await app.sendRequest(.GET, path + "?after=\(current)", beforeRequest: { $0.bearerAuth(bearer) })
            let page = try continuation.content.decode(Components.Schemas.StudyTaskPage.self)
            #expect(!page.items.isEmpty && page.items.allSatisfy { $0.id > current })
            items += page.items
            cursor = page.nextAfter
        }
        return (items, pages)
    }

    @Test
    func studyPagesExcludeOtherEnrollmentsAndBindTheContinuation() async throws {
        try await TestApp.withApp(token: StudyDataFixture.reader) { app, bearer in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let scheduleID = try await Self.assignTasks(fixture, on: app)
            let study = fixture.studyIDs[0]
            let path = "\(apiBasePath)/studies/\(study)/tasks"
            let response = try await app.sendRequest(.GET, path + "?limit=1", beforeRequest: { $0.bearerAuth(bearer) })
            try #require(response.status == .ok)
            #expect(response.headers.first(name: .cacheControl) == "no-store")
            let first = try response.content.decode(Components.Schemas.StudyTaskPage.self)
            try #require(first.items.count == 1)
            let after = try #require(first.nextAfter)
            #expect(after == first.items[0].id)
            let (rest, continuations) = try await Self.continuation(path: path, after: after, bearer: bearer, on: app)
            let pages = continuations + 1
            for item in first.items + rest {
                let enrollmentID = fixture.enrollmentIDs[0]
                let publicationID = try #require(UUID(uuidString: item.publicationId))
                #expect(UUID(uuidString: item.enrollmentId) == enrollmentID)
                #expect(UUID(uuidString: item.scheduleId) == scheduleID)
                #expect(item.id == TaskOccurrenceID.make(enrollment: enrollmentID, publication: publicationID, schedule: scheduleID, due: item.dueAt))
            }
            let other = "\(apiBasePath)/studies/\(fixture.studyIDs[1])/tasks"
            for invalid in [other + "?after=\(after)", path + "?limit=0", path + "?limit=101", path + "?after=invalid"] {
                try await app.test(.GET, invalid, beforeRequest: { $0.bearerAuth(bearer) }) { result in
                    #expect(result.status == .badRequest)
                }
            }
            let sql = try #require(app.db as? any SQLDatabase)
            let audits = try await sql.raw("""
                SELECT target_id FROM audit_events WHERE action = 'tasks.disclosure'
                """)
                .all()
            #expect(try audits.map { try $0.decode(column: "target_id", as: UUID.self) } == Array(repeating: study, count: pages))
        }
    }


    @Test(arguments: [
        TestApp.Token.none, .participant(subject: "test-participant"), .researcher(groups: ["/Test Group/researcher"]),
        .researcher(groups: ["/Other Group/researcher", "/Other Group/data-reader"])
    ])
    func requiresStudyDataAccess(token: TestApp.Token) async throws {
        try await TestApp.withApp(token: token) { app, bearer in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await app.test(.GET, "\(apiBasePath)/studies/\(fixture.studyIDs[0])/tasks", beforeRequest: { $0.bearerAuth(bearer) }) {
                #expect($0.status == (bearer == nil ? .unauthorized : .forbidden))
            }
        }
    }

    @Test
    func auditFailureBlocksEvenAnEmptyPage() async throws {
        try await TestApp.withApp(token: StudyDataFixture.reader) { app, bearer in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let sql = try #require(app.db as? any SQLDatabase)
            if app.db is any PostgresDatabase {
                try await sql.raw("""
                    CREATE TRIGGER reject_task_read BEFORE INSERT ON audit_events FOR EACH ROW
                    WHEN (NEW.action = 'tasks.disclosure') EXECUTE FUNCTION trove_reject_audit_mutation()
                    """)
                    .run()
            } else {
                try await sql.raw("""
                    CREATE TRIGGER reject_task_read BEFORE INSERT ON audit_events WHEN NEW.action = 'tasks.disclosure'
                    BEGIN SELECT RAISE(ABORT, 'Synthetic audit failure'); END
                    """)
                    .run()
            }
            try await app.test(.GET, "\(apiBasePath)/studies/\(fixture.studyIDs[0])/tasks", beforeRequest: { $0.bearerAuth(bearer) }) {
                #expect($0.status == .internalServerError)
                #expect(!$0.body.string.contains("items"))
            }
        }
    }
}
