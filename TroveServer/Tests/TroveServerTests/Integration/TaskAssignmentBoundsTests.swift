//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import GroveScheduler
import GroveStudyDefinition
import SQLKit
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


/// Assignment bounds: one-time occurrences due before the first consent, and the enrollment end.
struct TaskAssignmentBoundsTests {
    /// The participant's assignments in an enrollment whose end the test moves into the past.
    private struct Assigned {
        let enrollmentID: UUID
        let ids: Set<String>
        let checkpoint: UUID
    }

    /// An enrollment late on one civil day with consent on the next, and an enrollment after the scheduled time.
    @Test
    func oneTimeOccurrencesDueBeforeTheFirstConsentStayAssignableWhileOpen() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app, consentCount: 0)
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = .gmt
            let today = utc.startOfDay(for: Date())
            let lateEvening = today.addingTimeInterval(-600)
            let nine = today.addingTimeInterval(-15 * 3600)
            let onEnrollment = ParticipantTaskTests.plan(.once(.event(.enrollment)), policy: .anytime)
            let atNine = ParticipantTaskTests.plan(.once(.event(.enrollment, time: .init(hour: 9))), policy: .afterStart)
            // A same-day window that has closed, and an enrollment-relative day before the enrollment day.
            let closed = ParticipantTaskTests.plan(.once(.event(.enrollment)), policy: .sameDay)
            let dayBefore = ParticipantTaskTests.plan(.once(.event(.enrollment, offsetInDays: -1)), policy: .anytime)
            let closedAtNine = ParticipantTaskTests.plan(.once(.event(.enrollment, time: .init(hour: 9))), policy: .sameDayAfterStart)
            let schedules = [[onEnrollment, closed, dayBefore], [atNine, closedAtNine]]
            // Enrolled at 23:50 and at 14:00 on the previous civil day.
            try await Self.adopt(fixture, schedules: schedules, enrolledAt: [lateEvening, today.addingTimeInterval(-10 * 3600)], on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let service = app.grove[ConsentService.self]
                let evening = try await service.taskPage(enrollmentID: fixture.enrollmentIDs[0], cursor: nil, limit: 100)
                #expect(evening.items.map(\.scheduleId) == [onEnrollment.schedule.id.uuidString.lowercased()])
                let assigned = try #require(evening.items.first)
                #expect(abs(assigned.dueAt.timeIntervalSince(lateEvening)) < 0.001 && assigned.cutoffAt == nil)
                #expect(assigned.opensAt > assigned.dueAt && assigned.assignedAt >= assigned.opensAt)
                let morning = try await service.taskPage(enrollmentID: fixture.enrollmentIDs[1], cursor: nil, limit: 100)
                #expect(morning.items.map(\.scheduleId) == [atNine.schedule.id.uuidString.lowercased()])
                let backdated = try #require(morning.items.first)
                #expect(abs(backdated.dueAt.timeIntervalSince(nine)) < 0.001)
                try await Self.expectNoReassignment(enrollmentID: fixture.enrollmentIDs[0], snapshot: evening, on: app)
            }
        }
    }

    @Test
    func enrollmentEndBoundsAssignmentsAndClosesThemOnceItPasses() async throws {
        try await TestApp.withApp(token: StudyDataFixture.reader) { app, bearer in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let existing = try #require(try await Study.find(fixture.studyIDs[0], on: app.db))
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: existing.$group.id)
            let studyID = try study.requireID()
            let assigned = try await Self.assignWithinEnrollmentEnd(studyID: studyID, on: app)
            let path = "\(apiBasePath)/studies/\(studyID)/tasks?limit=100"
            #expect(try await Self.studyTaskIDs(path, bearer: bearer, on: app) == assigned.ids)

            // The enrollment end passes.
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("UPDATE enrollments SET ends_at = \(bind: Date()) WHERE id = \(bind: assigned.enrollmentID)").run()
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let service = app.grove[ConsentService.self]
                let delta = try await service.taskPage(enrollmentID: assigned.enrollmentID, cursor: assigned.checkpoint, limit: 100)
                #expect(delta.items.isEmpty && Set(delta.invalidated) == assigned.ids)
                let snapshot = try await service.taskPage(enrollmentID: assigned.enrollmentID, cursor: nil, limit: 100)
                #expect(snapshot.items.isEmpty && snapshot.invalidated.isEmpty)
            }
            #expect(try await Enrollment.find(assigned.enrollmentID, on: app.db)?.taskClosureBase != nil)
            let unstamped = try await sql.raw("""
                SELECT id FROM task_occurrences WHERE enrollment_id = \(bind: assigned.enrollmentID) AND invalidated_at IS NULL
                """)
                .all()
            #expect(unstamped.isEmpty)
            #expect(try await Self.studyTaskIDs(path, bearer: bearer, on: app).isEmpty)
        }
    }
}


extension TaskAssignmentBoundsTests {
    /// Publishes revision 2 of each study with its schedules, moves each enrollment instant, and accepts the first consent.
    private static func adopt(
        _ fixture: ClinicalEventStoreTests.Fixture,
        schedules: [[PublishedTaskSchedule]],
        enrolledAt: [Date],
        on app: Application
    ) async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        for index in schedules.indices {
            let id = fixture.enrollmentIDs[index]
            try await PublishedStudyFixtures.createPublishedStudy(
                on: app.db, studyId: fixture.studyIDs[index], revision: 2, taskSchedules: schedules[index]
            )
            try await sql.raw("UPDATE enrollments SET created_at = \(bind: enrolledAt[index]) WHERE id = \(bind: id)").run()
            _ = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await ClinicalEventStoreTests.acceptConsent(enrollmentID: id, on: app, revision: 2)
            }
        }
    }

    /// Later reads, also on a later day, find a backdated assignment by identity and never assign it twice.
    private static func expectNoReassignment(
        enrollmentID: UUID,
        snapshot: Components.Schemas.ParticipantTaskPage,
        on app: Application
    ) async throws {
        let service = app.grove[ConsentService.self]
        let repeated = try await service.taskPage(enrollmentID: enrollmentID, cursor: nil, limit: 100)
        #expect(repeated.snapshotVersion == snapshot.snapshotVersion && repeated.items == snapshot.items)
        let owned = try #require(try await Enrollment.find(enrollmentID, on: app.db))
        let context = try await service.verifiedStudyContext(enrollment: owned)
        try await app.db.transaction { transaction in
            let enrollment = try await service.repository.lockEnrollment(id: enrollmentID, on: transaction)
            let store = try TaskOccurrenceStore(
                on: transaction,
                enrollment: enrollment,
                context: context.audit,
                scope: .study(studyID: context.scope.studyID, groupID: context.scope.groupID)
            )
            #expect(try await store.reconcile(now: Date().addingTimeInterval(86_400)) == snapshot.snapshotVersion)
        }
        let sql = try #require(app.db as? any SQLDatabase)
        let rows = try await sql.raw("SELECT id FROM task_occurrences WHERE enrollment_id = \(bind: enrollmentID)").all()
        #expect(rows.count == snapshot.items.count)
    }

    /// Enrolls for two days, adopts a revision with daily and later one-time schedules, and checks the assigned bounds.
    private static func assignWithinEnrollmentEnd(studyID: UUID, on app: Application) async throws -> Assigned {
        let period = EnrollmentPeriod(calendar: .gregorian, timeZone: "UTC", duration: .init(day: 2))
        try await PublishedStudyFixtures.createPublishedStudy(on: app.db, studyId: studyID, enrollmentPeriod: period)
        let anytime = ParticipantTaskTests.plan(.repeated(.daily(hour: 12)), policy: .anytime)
        let afterEnd = ParticipantTaskTests.plan(.once(.event(.enrollment, offsetInDays: 3)), policy: .anytime)
        let schedules = [anytime, ParticipantTaskTests.plan(.repeated(.daily(hour: 12)), policy: .sameDay), afterEnd]
        try await PublishedStudyFixtures.createPublishedStudy(
            on: app.db, studyId: studyID, revision: 2, enrollmentPeriod: period, taskSchedules: schedules
        )
        return try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            let id = try await app.grove[ParticipantEnrollmentService.self].enroll(studyId: studyID, invitationCode: nil).requireID()
            _ = try await ClinicalEventStoreTests.acceptConsent(enrollmentID: id, on: app, revision: 2)
            let end = try #require(try await Enrollment.find(id, on: app.db)?.endsAt)
            let page = try await app.grove[ConsentService.self].taskPage(enrollmentID: id, cursor: nil, limit: 100)
            try #require(!page.items.isEmpty)
            #expect(page.items.count <= 6 && page.items.allSatisfy { $0.dueAt < end })
            #expect(!page.items.contains { $0.scheduleId == afterEnd.schedule.id.uuidString.lowercased() })
            for item in page.items {
                let cutoff = try #require(item.cutoffAt)
                #expect(cutoff.timeIntervalSince(end) < 0.001)
                if item.scheduleId == anytime.schedule.id.uuidString.lowercased() {
                    #expect(abs(cutoff.timeIntervalSince(end)) < 0.001)
                }
            }
            let checkpoint = try #require(page.checkpoint.flatMap(UUID.init(uuidString:)))
            return Assigned(enrollmentID: id, ids: Set(page.items.map(\.id)), checkpoint: checkpoint)
        }
    }

    private static func studyTaskIDs(_ path: String, bearer: String?, on app: Application) async throws -> Set<String> {
        let response = try await app.sendRequest(.GET, path, beforeRequest: { $0.bearerAuth(bearer) })
        try #require(response.status == .ok)
        return Set(try response.content.decode(Components.Schemas.StudyTaskPage.self).items.map(\.id))
    }
}
