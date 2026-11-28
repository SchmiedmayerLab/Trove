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
import GroveScheduler
import GroveStudyDefinition
import SQLKit
import Testing
import TroveAPIServer
import VaporTesting


@testable import TroveServer


struct ParticipantTaskTests {
    private static var schedule: PublishedTaskSchedule {
        plan(.repeated(.daily(hour: 12), offset: .init(day: 1)))
    }

    static func plan(
        _ definition: StudyDefinition.ComponentSchedule.ScheduleDefinition,
        policy: GroveScheduler.AllowedCompletionPolicy = .sameDayAfterStart
    ) -> PublishedTaskSchedule {
        PublishedTaskSchedule(
            schedule: .init(
                id: UUID(),
                componentId: UUID(),
                scheduleDefinition: definition,
                completionPolicy: policy,
                notifications: .disabled
            ),
            questionnaireSHA256: String(repeating: "a", count: 64),
            language: "en-US",
            administrationLanguages: ["en-US"],
            questionnaireCanonical: "https://example.test/fhir/Questionnaire/synthetic|1.0.0"
        )
    }

    @Test
    func oneTimeRulesRespectEnrollmentAndTheHalfOpenWindow() throws {
        let enrollment = Date(timeIntervalSince1970: 1_767_225_600)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let nextDay = try #require(calendar.date(byAdding: .day, value: 1, to: enrollment))
        func dates(_ definition: StudyDefinition.ComponentSchedule.ScheduleDefinition, until end: Date) throws -> [Date] {
            try Self.plan(definition).dates(enrolledAt: enrollment, from: enrollment, until: end, calendar: calendar)
        }
        let absolute = calendar.dateComponents([.year, .month, .day], from: nextDay)
        #expect(try dates(.once(.date(absolute)), until: nextDay).isEmpty)
        #expect(try dates(.once(.date(absolute)), until: nextDay.addingTimeInterval(1)) == [nextDay])
        #expect(try dates(.once(.event(.enrollment, offsetInDays: 1, time: nil)), until: nextDay.addingTimeInterval(1)) == [nextDay])
        #expect(try dates(.once(.event(.completedTask(componentId: UUID()), offsetInDays: 0, time: nil)), until: nextDay).isEmpty)
    }

    @Test
    func scheduleRecordsTheQuestionnaireCanonicalAndVersion() throws {
        let schedule = Self.schedule.schedule
        let instrument = PublishedInstrument(
            componentID: schedule.componentId,
            sha256: String(repeating: "b", count: 64),
            language: "en-US",
            translationLanguages: [],
            administrationLanguages: []
        )
        let resource = Data(#"{"resourceType":"Questionnaire","url":"https://example.test/fhir/Questionnaire/q","version":"2.1.0"}"#.utf8)
        let plan = try PublishedTaskSchedule(schedule: schedule, instrument: instrument, questionnaire: resource)
        #expect(plan.questionnaireCanonical == "https://example.test/fhir/Questionnaire/q|2.1.0")
        #expect(plan.questionnaireSHA256 == instrument.sha256)
        let unversioned = Data(#"{"resourceType":"Questionnaire","url":"https://example.test/fhir/Questionnaire/q"}"#.utf8)
        #expect(throws: ServerError.self) {
            try PublishedTaskSchedule(schedule: schedule, instrument: instrument, questionnaire: unversioned)
        }
    }

    @Test
    func delayedConsentOnlyBackdatesEnrollmentTriggeredWork() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let enrolled = try #require(calendar.date(from: .init(year: 2026, month: 3, day: 1, hour: 8)))
        let accepted = enrolled.addingTimeInterval(9 * 3600)
        let tomorrow = calendar.startOfDay(for: enrolled).addingTimeInterval(86_400)
        func dates(_ definition: StudyDefinition.ComponentSchedule.ScheduleDefinition, first: Bool) throws -> [Date] {
            let plan = Self.plan(definition)
            let start = plan.eligibleFrom(enrolledAt: enrolled, acceptedAt: accepted, firstAdoption: first)
            return try plan.dates(enrolledAt: enrolled, from: start, until: tomorrow, calendar: calendar)
        }
        #expect(try dates(.once(.event(.enrollment)), first: true) == [enrolled])
        #expect(try dates(.once(.event(.enrollment)), first: false).isEmpty)
        #expect(try dates(.repeated(.daily(hour: 9)), first: true).isEmpty)
        #expect(try dates(.repeated(.daily(hour: 18)), first: true) == [accepted.addingTimeInterval(3600)])
    }

    @Test
    func expiredPageRequiresFreshAuthenticatedSnapshot() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, credential in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let id = fixture.enrollmentIDs[0]
            let path = "\(apiBasePath)/participant/enrollments/\(id)/tasks"
            var checkpoint: UUID?
            try await app.test(.GET, path, beforeRequest: { $0.bearerAuth(credential) }) { response in
                try #require(response.status == .ok)
                #expect(response.headers.first(name: "Cache-Control") == "no-store")
                let page = try JSONDecoder().decode(Components.Schemas.ParticipantTaskPage.self, from: Data(response.body.readableBytesView))
                checkpoint = try #require(page.checkpoint.flatMap(UUID.init(uuidString:)))
            }
            let expired = try #require(checkpoint)
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("UPDATE task_sync_cursors SET expires_at = \(bind: Date(timeIntervalSince1970: 1)) WHERE id = \(bind: expired)").run()
            let retained = try await sql.raw("SELECT id FROM task_sync_cursors WHERE id = \(bind: expired)").first()
            try #require(retained != nil)
            try await app.test(.GET, "\(path)?cursor=\(expired)", beforeRequest: { $0.bearerAuth(credential) }) { response in
                #expect(response.status == .gone)
            }
            try await app.test(.GET, path, beforeRequest: { $0.bearerAuth(credential) }) { response in
                try #require(response.status == .ok)
                let fresh = try JSONDecoder().decode(Components.Schemas.ParticipantTaskPage.self, from: Data(response.body.readableBytesView))
                let freshID = try #require(fresh.checkpoint.flatMap(UUID.init(uuidString:)))
                #expect(freshID != expired)
            }
            try await app.test(.GET, path) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func failedAssignmentAuditRollsBackAdoptionAndTasks() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let id = fixture.enrollmentIDs[0]
            _ = try await PublishedStudyFixtures.createPublishedStudy(
                on: app.db,
                studyId: fixture.studyIDs[0],
                revision: 2,
                taskSchedules: [Self.schedule]
            )
            let sql = try #require(app.db as? any SQLDatabase)
            if app.db is any PostgresDatabase {
                try await sql.raw("""
                    CREATE TRIGGER reject_tasks BEFORE INSERT ON audit_events FOR EACH ROW
                    WHEN (NEW.action = 'tasks.assigned') EXECUTE FUNCTION trove_reject_audit_mutation()
                    """)
                    .run()
            } else {
                try await sql.raw("""
                    CREATE TRIGGER reject_tasks BEFORE INSERT ON audit_events WHEN NEW.action = 'tasks.assigned'
                    BEGIN SELECT RAISE(ABORT, 'Synthetic assignment audit failure'); END
                    """)
                    .run()
            }
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                await #expect(throws: (any Error).self) { try await ClinicalEventStoreTests.acceptConsent(enrollmentID: id, on: app, revision: 2) }
                let enrollment = try #require(try await Enrollment.find(id, on: app.db))
                #expect(enrollment.currentRevision == 1)
                let page = try await app.grove[ConsentService.self].taskPage(enrollmentID: id, cursor: nil, limit: 1)
                #expect(page.items.isEmpty && page.snapshotVersion == 0)
            }
        }
    }

    @Test
    func newAssignmentsDuringPaginationStartTheNextDelta() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let id = fixture.enrollmentIDs[0]
            _ = try await PublishedStudyFixtures.createPublishedStudy(
                on: app.db, studyId: fixture.studyIDs[0], revision: 2, taskSchedules: [Self.schedule]
            )
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await ClinicalEventStoreTests.acceptConsent(enrollmentID: id, on: app, revision: 2)
                let service = app.grove[ConsentService.self]
                let first = try await service.taskPage(enrollmentID: id, cursor: nil, limit: 1)
                let cursor = try #require(first.nextCursor.flatMap(UUID.init(uuidString:)))
                let owned = try #require(try await Enrollment.find(id, on: app.db))
                let context = try await service.verifiedStudyContext(enrollment: owned)
                let tomorrow = Date().addingTimeInterval(86_400)
                try await app.db.transaction { transaction in
                    let enrollment = try await service.repository.lockEnrollment(id: id, on: transaction)
                    let store = try TaskOccurrenceStore(
                        on: transaction,
                        enrollment: enrollment,
                        context: context.audit,
                        scope: .study(studyID: context.scope.studyID, groupID: context.scope.groupID)
                    )
                    let later = try await store.reconcile(now: tomorrow)
                    #expect(later > first.snapshotVersion)
                }
                let last = try await service.taskPage(enrollmentID: id, cursor: cursor, limit: 100)
                #expect(last.snapshotVersion == first.snapshotVersion && last.items.allSatisfy { $0.version <= first.snapshotVersion })
                let checkpoint = try #require(last.checkpoint.flatMap(UUID.init(uuidString:)))
                let delta = try await service.taskPage(enrollmentID: id, cursor: checkpoint, limit: 100)
                #expect(!delta.items.isEmpty && delta.items.allSatisfy { $0.version > first.snapshotVersion })
            }
        }
    }

    @Test
    func forwardAdoptionRetainsPastAssignmentsAndReplacesFutureOnes() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app, consentCount: 0)
            let id = fixture.enrollmentIDs[0]
            let studyID = fixture.studyIDs[0]
            let daily = Self.schedule
            let immediate = Self.plan(.once(.event(.enrollment)))
            let triggerID = immediate.schedule.id
            try await PublishedStudyFixtures.createPublishedStudy(on: app.db, studyId: studyID, revision: 2, taskSchedules: [daily, immediate])
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let service = app.grove[ConsentService.self]
                _ = try await ClinicalEventStoreTests.acceptConsent(enrollmentID: id, on: app, revision: 2)
                let original = try await service.taskPage(enrollmentID: id, cursor: nil, limit: 100)
                let past = try #require(original.items.first { $0.scheduleId == triggerID.uuidString.lowercased() })
                let future = Set(original.items.filter { $0.id != past.id }.map(\.id))
                try #require(!future.isEmpty)
                let checkpoint = try #require(original.checkpoint.flatMap(UUID.init(uuidString:)))

                try await PublishedStudyFixtures.createPublishedStudy(on: app.db, studyId: studyID, revision: 3, taskSchedules: [daily])
                _ = try await ClinicalEventStoreTests.acceptConsent(enrollmentID: id, on: app, revision: 3)
                let delta = try await TaskCompletionFixture.drain(service, enrollment: id, from: checkpoint)
                #expect(Set(delta.invalidated) == future)
                #expect(!delta.items.isEmpty && delta.items.allSatisfy { $0.revision == 3 })
                let snapshot = try await TaskCompletionFixture.drain(service, enrollment: id, from: nil)
                #expect(snapshot.items.filter { $0.revision == 2 } == [past])
                #expect(Set(snapshot.items.map(\.id)) == Set(delta.items.map(\.id)).union([past.id]))
            }
        }
    }

    @Test
    func adoptedRevisionPagesAndInvalidations() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let id = fixture.enrollmentIDs[0]
            let schedule = Self.schedule
            let publication = try await PublishedStudyFixtures.createPublishedStudy(
                on: app.db,
                studyId: fixture.studyIDs[0],
                revision: 2,
                taskSchedules: [schedule]
            )
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let service = app.grove[ConsentService.self]
                let initial = try await service.taskPage(enrollmentID: id, cursor: nil, limit: 1)
                #expect(initial.items.isEmpty && initial.snapshotVersion == 0)
                _ = try await ClinicalEventStoreTests.acceptConsent(enrollmentID: id, on: app, revision: 2)
                let first = try await service.taskPage(enrollmentID: id, cursor: nil, limit: 1)
                let item = try #require(first.items.first)
                #expect(item.publicationId == publication.id?.uuidString.lowercased())
                #expect(item.sha256 == schedule.questionnaireSHA256 && item.scheduleId == schedule.schedule.id.uuidString.lowercased())
                let cursor = try #require(first.nextCursor.flatMap(UUID.init(uuidString:)))
                let next = try await service.taskPage(enrollmentID: id, cursor: cursor, limit: 100)
                #expect(first.snapshotVersion == next.snapshotVersion)
                #expect(next.items.allSatisfy { $0.version > item.version && $0.id != item.id })
                let checkpoint = try #require(next.checkpoint.flatMap(UUID.init(uuidString:)))
                let unchanged = try await service.taskPage(enrollmentID: id, cursor: checkpoint, limit: 100)
                #expect(unchanged.items.isEmpty && unchanged.invalidated.isEmpty && unchanged.snapshotVersion == next.snapshotVersion)
                await #expect(throws: ServerError.self) {
                    try await service.taskPage(enrollmentID: fixture.enrollmentIDs[1], cursor: checkpoint, limit: 10)
                }
                _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: id)
                await #expect(throws: ServerError.self) { try await service.taskPage(enrollmentID: id, cursor: cursor, limit: 10) }
                let withdrawn = try await service.taskPage(enrollmentID: id, cursor: checkpoint, limit: 100)
                #expect(withdrawn.items.isEmpty && Set(withdrawn.invalidated) == Set(([item] + next.items).map(\.id)))
                let snapshot = try await service.taskPage(enrollmentID: id, cursor: nil, limit: 100)
                #expect(snapshot.items.isEmpty && snapshot.snapshotVersion == withdrawn.snapshotVersion)
            }
        }
    }
}
