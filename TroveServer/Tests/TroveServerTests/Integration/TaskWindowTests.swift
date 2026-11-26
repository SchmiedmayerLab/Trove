//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SQLKit
import Testing
@testable import TroveServer
import VaporTesting


/// Assigned windows follow the completion policy, the study time zone and the enrollment end.
struct TaskWindowTests {
    /// `policy` names a completion policy: `anytime`, `afterStart` or `sameDay`.
    private static func schedule(_ policy: String) -> PublishedTaskSchedule {
        PublishedTaskSchedule(
            schedule: .init(
                id: UUID(),
                componentId: UUID(),
                scheduleDefinition: .repeated(.daily(hour: 12), offset: .init(day: 1)),
                completionPolicy: policy == "anytime" ? .anytime : policy == "afterStart" ? .afterStart : .sameDay,
                notifications: .disabled
            ),
            questionnaireSHA256: String(repeating: "a", count: 64),
            language: "en-US",
            administrationLanguages: ["en-US", "de"],
            questionnaireCanonical: "https://example.test/fhir/Questionnaire/synthetic|1.0.0"
        )
    }

    @Test(arguments: ["anytime", "afterStart"])
    func ongoingEnrollmentsAssignDeadlineFreeOccurrences(policy: String) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let id = fixture.enrollmentIDs[0]
            let schedule = Self.schedule(policy)
            _ = try await PublishedStudyFixtures.createPublishedStudy(
                on: app.db, studyId: fixture.studyIDs[0], revision: 2, taskSchedules: [schedule]
            )
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await ClinicalEventStoreTests.acceptConsent(enrollmentID: id, on: app, revision: 2)
                let page = try await app.grove[ConsentService.self].taskPage(enrollmentID: id, cursor: nil, limit: 100)
                #expect(!page.items.isEmpty)
                #expect(page.items.allSatisfy { $0.cutoffAt == nil && $0.administrationLanguages == ["en-US", "de"] })
                #expect(page.items.allSatisfy { TaskWindow($0).admits($0.dueAt.addingTimeInterval(400 * 86_400)) })
                let sql = try #require(app.db as? any SQLDatabase)
                let rows = try await sql.raw("SELECT cutoff_at FROM task_occurrences WHERE enrollment_id = \(bind: id)").all()
                #expect(rows.count == page.items.count)
                #expect(try rows.allSatisfy { try $0.decodeNil(column: "cutoff_at") })
            }
        }
    }

    @Test
    func sameDayOccurrencesEndAtTheEndOfTheirLocalDay() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let id = fixture.enrollmentIDs[0]
            _ = try await PublishedStudyFixtures.createPublishedStudy(
                on: app.db, studyId: fixture.studyIDs[0], revision: 2, taskSchedules: [Self.schedule("sameDay")]
            )
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await ClinicalEventStoreTests.acceptConsent(enrollmentID: id, on: app, revision: 2)
                let page = try await app.grove[ConsentService.self].taskPage(enrollmentID: id, cursor: nil, limit: 100)
                let item = try #require(page.items.first)
                let cutoff = try #require(item.cutoffAt)
                #expect(TaskWindow(item).hasEnded(at: cutoff) && !TaskWindow(item).admits(cutoff))
                let sql = try #require(app.db as? any SQLDatabase)
                let stored = try await sql.raw("SELECT cutoff_at FROM task_occurrences WHERE id = \(bind: item.id)").first()
                #expect(try stored?.decode(column: "cutoff_at", as: Date.self).timeIntervalSince(cutoff).magnitude ?? 1 < 0.001)
            }
        }
    }

    /// A revision that changes the study time zone reassigns future work in the new zone and keeps earlier work.
    @Test
    func aTimeZoneChangeKeepsAssignedWorkAndMovesFutureWork() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app, consentCount: 0)
            let id = fixture.enrollmentIDs[0]
            let studyID = fixture.studyIDs[0]
            let daily = Self.schedule("sameDay")
            let pacificPeriod = EnrollmentPeriod(calendar: .gregorian, timeZone: "America/Los_Angeles")
            try await PublishedStudyFixtures.createPublishedStudy(
                on: app.db, studyId: studyID, revision: 2, enrollmentPeriod: pacificPeriod, taskSchedules: [daily]
            )
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let service = app.grove[ConsentService.self]
                _ = try await ClinicalEventStoreTests.acceptConsent(enrollmentID: id, on: app, revision: 2)
                let original = try await service.taskPage(enrollmentID: id, cursor: nil, limit: 100)
                try #require(!original.items.isEmpty)
                #expect(original.items.allSatisfy { $0.timeZone == "America/Los_Angeles" })
                var pacific = Calendar(identifier: .gregorian)
                pacific.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
                #expect(original.items.allSatisfy { pacific.component(.hour, from: $0.dueAt) == 12 })
                let checkpoint = try #require(original.checkpoint.flatMap(UUID.init(uuidString:)))

                let berlinPeriod = EnrollmentPeriod(calendar: .gregorian, timeZone: "Europe/Berlin")
                try await PublishedStudyFixtures.createPublishedStudy(
                    on: app.db, studyId: studyID, revision: 3, enrollmentPeriod: berlinPeriod, taskSchedules: [daily]
                )
                let adopted = try await ClinicalEventStoreTests.acceptConsent(enrollmentID: id, on: app, revision: 3)
                let delta = try await service.taskPage(enrollmentID: id, cursor: checkpoint, limit: 100)
                let moved = Set(original.items.filter { $0.dueAt >= adopted.createdAt ?? .distantFuture }.map(\.id))
                #expect(Set(delta.invalidated) == moved)
                var berlin = Calendar(identifier: .gregorian)
                berlin.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
                #expect(!delta.items.isEmpty)
                #expect(delta.items.allSatisfy { $0.timeZone == "Europe/Berlin" && berlin.component(.hour, from: $0.dueAt) == 12 })
                let snapshot = try await service.taskPage(enrollmentID: id, cursor: nil, limit: 100)
                // Work assigned before the adoption keeps its zone and instant.
                let kept = original.items.filter { !moved.contains($0.id) }
                #expect(Set(snapshot.items.filter { $0.revision == 2 }.map(\.id)) == Set(kept.map(\.id)))
            }
        }
    }
}
