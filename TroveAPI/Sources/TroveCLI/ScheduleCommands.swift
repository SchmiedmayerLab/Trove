//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import ArgumentParser
import Foundation
import TroveAPIClient


private enum ScheduleReply {
    /// The reply must carry the notification setting and reminder time that were sent.
    static func requireStored(_ input: Components.Schemas.ComponentScheduleInput, in schedule: Components.Schemas.ComponentSchedule) throws {
        guard schedule.notification == input.notification, normalized(schedule.reminderTime) == normalized(input.reminderTime) else {
            throw CLIError.requestFailed
        }
    }

    private static func normalized(_ time: Components.Schemas.ScheduleTime?) -> Components.Schemas.ScheduleTime? {
        time.map { .init(hour: $0.hour, minute: $0.minute ?? 0, second: $0.second ?? 0) }
    }
}


struct ScheduleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schedule",
        abstract: "Read and author the schedules of a draft component.",
        discussion: """
            A ComponentScheduleInput sets the schedule definition, the completion policy, whether occurrences \
            notify the participant and, with notifications, an optional reminder time of day.
            """,
        subcommands: [ListSchedules.self, AddSchedule.self, ReplaceSchedule.self]
    )
}


struct ListSchedules: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List the schedules of a draft component.")
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var draft: DraftAccessOptions
    @Argument(transform: CLIInput.uuid) var study: UUID
    @Option(help: "The component ID.", transform: CLIInput.uuid) var component: UUID

    mutating func run() async throws {
        let client = try connection.client()
        try CLIInput.write(try await client.listSchedules(study, component: component, delegation: draft.delegation))
    }
}


struct AddSchedule: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a schedule to a reviewed draft component.")
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var draft: DraftAccessOptions
    @Argument(transform: CLIInput.uuid) var study: UUID
    @Option(help: "The component ID.", transform: CLIInput.uuid) var component: UUID
    @Option(help: "The draft revision captured when preparing this edit.", transform: CLIInput.uuid) var revision: UUID
    @Option(help: "Path to a ComponentScheduleInput JSON file.") var file: String

    mutating func run() async throws {
        let input = try CLIInput.decode(Components.Schemas.ComponentScheduleInput.self, file: file)
        let client = try connection.client()
        try CLIInput.write(try await client.addSchedule(study, component: component, revision: revision, delegation: draft.delegation, input: input))
    }
}


struct ReplaceSchedule: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "replace", abstract: "Replace a schedule of a reviewed draft component.")
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var draft: DraftAccessOptions
    @Argument(transform: CLIInput.uuid) var study: UUID
    @Option(help: "The component ID.", transform: CLIInput.uuid) var component: UUID
    @Option(help: "The schedule ID.", transform: CLIInput.uuid) var schedule: UUID
    @Option(help: "The draft revision captured when preparing this edit.", transform: CLIInput.uuid) var revision: UUID
    @Option(help: "Path to a ComponentScheduleInput JSON file.") var file: String

    mutating func run() async throws {
        let input = try CLIInput.decode(Components.Schemas.ComponentScheduleInput.self, file: file)
        let client = try connection.client()
        try CLIInput.write(try await client.replaceSchedule(
            study, component: component, schedule: schedule, revision: revision, delegation: draft.delegation, input: input
        ))
    }
}


extension AuthoringClient {
    func listSchedules(_ study: UUID, component: UUID, delegation: UUID?) async throws -> [Components.Schemas.ComponentSchedule] {
        try await request(revision: nil) { client in
            try await client.getStudiesStudyIdComponentsComponentIdSchedules(.init(
                path: .init(studyId: study.uuidString, componentId: component.uuidString),
                headers: .init(troveDelegationID: delegation?.uuidString)
            )).ok.body.json
        }
    }

    func addSchedule(
        _ study: UUID, component: UUID, revision: UUID, delegation: UUID?, input: Components.Schemas.ComponentScheduleInput
    ) async throws -> Components.Schemas.ComponentSchedule {
        try await request(revision: revision) { client in
            let schedule = try await client.postStudiesStudyIdComponentsComponentIdSchedules(.init(
                path: .init(studyId: study.uuidString, componentId: component.uuidString),
                headers: .init(troveDelegationID: delegation?.uuidString, ifMatch: CLIInput.revisionHeader(revision)),
                body: .json(input)
            )).created.body.json
            try ScheduleReply.requireStored(input, in: schedule)
            return schedule
        }
    }

    // swiftlint:disable:next function_parameter_count
    func replaceSchedule(
        _ study: UUID, component: UUID, schedule: UUID, revision: UUID, delegation: UUID?, input: Components.Schemas.ComponentScheduleInput
    ) async throws -> Components.Schemas.ComponentSchedule {
        try await request(revision: revision) { client in
            let replaced = try await client.putStudiesStudyIdComponentsComponentIdSchedulesScheduleId(.init(
                path: .init(studyId: study.uuidString, componentId: component.uuidString, scheduleId: schedule.uuidString),
                headers: .init(troveDelegationID: delegation?.uuidString, ifMatch: CLIInput.revisionHeader(revision)),
                body: .json(input)
            )).ok.body.json
            guard UUID(uuidString: replaced.id) == schedule else {
                throw CLIError.requestFailed
            }
            try ScheduleReply.requireStored(input, in: replaced)
            return replaced
        }
    }
}
