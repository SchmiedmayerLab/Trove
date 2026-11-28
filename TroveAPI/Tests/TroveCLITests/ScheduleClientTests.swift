//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Testing
import TroveAPIClient
@testable import TroveCLI


struct ScheduleClientTests {
    private let study = UUID()
    private let component = UUID()
    private let revision = UUID()
    private let input = Components.Schemas.ComponentScheduleInput(
        scheduleDefinition: .repeated(.init(_type: .repeated, pattern: .daily(.init(_type: .daily, hour: 9)))),
        completionPolicy: .sameDay,
        notification: true,
        reminderTime: .init(hour: 8, minute: 15)
    )

    private func client(_ transport: AuthoringTransport) throws -> AuthoringClient {
        let url = try #require(URL(string: "https://research.example/api/v0"))
        return AuthoringClient(serverURL: url, token: "synthetic-test-credential", transport: transport)
    }

    private func schedule(id: UUID = UUID(), reminder: Components.Schemas.ScheduleTime? = .init(hour: 8, minute: 15, second: 0))
        -> Components.Schemas.ComponentSchedule {
        .init(
            id: id.uuidString,
            scheduleDefinition: input.scheduleDefinition,
            completionPolicy: input.completionPolicy,
            notification: true,
            reminderTime: reminder
        )
    }

    @Test
    func addsAScheduleWithItsReminderTimeToTheReviewedRevision() async throws {
        let expected = schedule()
        let transport = try AuthoringTransport(response: expected, status: 201)
        #expect(try await client(transport).addSchedule(study, component: component, revision: revision, delegation: nil, input: input) == expected)
        let record = try #require(await transport.records.first)
        #expect(record.request.method == .post)
        #expect(record.request.path == "/studies/\(study.uuidString)/components/\(component.uuidString)/schedules")
        #expect(record.request.headerFields[.ifMatch] == CLIInput.revisionHeader(revision))
        let body = try JSONDecoder().decode(Components.Schemas.ComponentScheduleInput.self, from: record.body)
        #expect(body.reminderTime == input.reminderTime && body.notification)
    }

    @Test
    func replacesTheNamedScheduleAndChecksTheReply() async throws {
        let id = UUID()
        let transport = try AuthoringTransport(response: schedule(id: id))
        _ = try await client(transport).replaceSchedule(study, component: component, schedule: id, revision: revision, delegation: nil, input: input)
        let record = try #require(await transport.records.first)
        #expect(record.request.method == .put)
        #expect(record.request.path == "/studies/\(study.uuidString)/components/\(component.uuidString)/schedules/\(id.uuidString)")
        await #expect(throws: CLIError.requestFailed) {
            try await client(try AuthoringTransport(response: schedule())).replaceSchedule(
                study, component: component, schedule: id, revision: revision, delegation: nil, input: input
            )
        }
    }

    @Test
    func refusesAReplyWithoutTheSentReminderTime() async throws {
        for reply in [schedule(reminder: nil), schedule(reminder: .init(hour: 9))] {
            let transport = try AuthoringTransport(response: reply, status: 201)
            await #expect(throws: CLIError.requestFailed) {
                try await client(transport).addSchedule(study, component: component, revision: revision, delegation: nil, input: input)
            }
        }
    }

    @Test
    func listsTheSchedulesOfAComponent() async throws {
        let schedules = [schedule()]
        let transport = try AuthoringTransport(response: schedules)
        #expect(try await client(transport).listSchedules(study, component: component, delegation: nil) == schedules)
        let record = try #require(await transport.records.first)
        #expect(record.request.method == .get && record.request.headerFields[.ifMatch] == nil)
    }
}
