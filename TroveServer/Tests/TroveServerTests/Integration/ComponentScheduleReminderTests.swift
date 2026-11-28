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
import TroveAPIServer
@testable import TroveServer
import VaporTesting


struct ComponentScheduleReminderTests {
    /// The reminder time is authored per schedule, stored as Grove's notification time and refused without notifications.
    @Test
    func reminderTimeIsStoredOnlyWithNotifications() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let componentId = try await ComponentFixtures.createInformationalComponent(on: app.db, studyId: study.requireId()).requireId()
            let studyId = try study.requireId()
            func post(_ notification: Bool, _ reminder: [String: Any]) async throws -> TestingHTTPResponse {
                var body: [String: Any] = [
                    "scheduleDefinition": ["type": "repeated", "pattern": ["type": "daily", "hour": 9]], "completionPolicy": "anytime"
                ]
                body["notification"] = notification
                if !reminder.isEmpty {
                    body["reminderTime"] = reminder
                }
                let revision = try #require(try await Study.find(studyId, on: app.db)).draftRevision
                return try await app.sendRequest(.POST, "\(apiBasePath)/studies/\(studyId)/components/\(componentId)/schedules", beforeRequest: { req in
                    req.bearerAuth(token)
                    req.headers.replaceOrAdd(name: "If-Match", value: "\"\(revision)\"")
                    try req.encodeJSONBody(body)
                })
            }
            #expect(try await post(false, ["hour": 8]).status == .badRequest)
            #expect(try await post(true, ["hour": 24]).status == .badRequest)
            #expect(try await post(true, ["hour": 8, "minute": 60]).status == .badRequest)
            #expect(try await ComponentSchedule.query(on: app.db).count() == 0)

            let created = try await post(true, ["hour": 8, "minute": 15])
            #expect(created.status == .created)
            let schedule = try created.content.decode(Components.Schemas.ComponentSchedule.self)
            #expect(schedule.notification && schedule.reminderTime == .init(hour: 8, minute: 15))
            let stored = try #require(try await ComponentSchedule.find(UUID(uuidString: schedule.id), on: app.db))
            #expect(stored.scheduleData.notifications == .enabled(thread: .task, time: .init(hour: 8, minute: 15)))

            let plain = try await post(true, [:])
            #expect(try plain.content.decode(Components.Schemas.ComponentSchedule.self).reminderTime == nil)
        }
    }
}
