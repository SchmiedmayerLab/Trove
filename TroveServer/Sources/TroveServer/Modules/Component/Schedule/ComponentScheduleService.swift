//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import Grove
import GroveStudyDefinition


final class ComponentScheduleService: Module, @unchecked Sendable {
    @Dependency(StudyService.self) var studyService

    private static func requireSchedulableComponent(id: UUID, studyId: UUID, on transaction: any Database) async throws {
        guard let component = try await ComponentRepository(database: transaction).find(id: id, studyId: studyId) else {
            throw ServerError.notFound(resource: "Component", identifier: id.uuidString)
        }
        guard component.type.supportsSchedules else {
            throw ServerError.conflict("Component type '\(component.type.rawValue)' does not support schedules")
        }
    }

    func listSchedules(studyId: UUID, componentId: UUID) async throws -> [ComponentSchedule] {
        try await studyService.readDraft(id: studyId) { _, transaction in
            try await Self.requireSchedulableComponent(id: componentId, studyId: studyId, on: transaction)
            return try await ComponentScheduleRepository(database: transaction).findAll(componentId: componentId)
        }
    }

    func getSchedule(studyId: UUID, componentId: UUID, scheduleId: UUID) async throws -> ComponentSchedule {
        try await studyService.readDraft(id: studyId) { _, transaction in
            try await Self.requireSchedulableComponent(id: componentId, studyId: studyId, on: transaction)
            guard let schedule = try await ComponentScheduleRepository(database: transaction).find(id: scheduleId, componentId: componentId) else {
                throw ServerError.notFound(resource: "ComponentSchedule", identifier: scheduleId.uuidString)
            }
            return schedule
        }
    }

    func createSchedule(
        studyId: UUID,
        componentId: UUID,
        expectedRevision: UUID,
        data: StudyDefinition.ComponentSchedule
    ) async throws -> ComponentSchedule {
        try await studyService.editDraft(id: studyId, expectedRevision: expectedRevision) { _, transaction in
            try await Self.requireSchedulableComponent(id: componentId, studyId: studyId, on: transaction)
            let repository = ComponentScheduleRepository(database: transaction)
            return try await repository.create(ComponentSchedule(componentId: componentId, scheduleData: data))
        }
    }

    func replaceSchedule(
        studyId: UUID,
        componentId: UUID,
        scheduleId: UUID,
        expectedRevision: UUID,
        data: StudyDefinition.ComponentSchedule
    ) async throws -> ComponentSchedule {
        try await studyService.editDraft(id: studyId, expectedRevision: expectedRevision) { _, transaction in
            try await Self.requireSchedulableComponent(id: componentId, studyId: studyId, on: transaction)
            let repository = ComponentScheduleRepository(database: transaction)
            guard let schedule = try await repository.find(id: scheduleId, componentId: componentId) else {
                throw ServerError.notFound(resource: "ComponentSchedule", identifier: scheduleId.uuidString)
            }
            schedule.scheduleData = data
            return try await repository.update(schedule)
        }
    }

    func deleteSchedule(studyId: UUID, componentId: UUID, scheduleId: UUID, expectedRevision: UUID) async throws {
        try await studyService.editDraft(id: studyId, expectedRevision: expectedRevision) { _, transaction in
            try await Self.requireSchedulableComponent(id: componentId, studyId: studyId, on: transaction)
            guard try await ComponentScheduleRepository(database: transaction).delete(id: scheduleId, componentId: componentId) else {
                throw ServerError.notFound(resource: "ComponentSchedule", identifier: scheduleId.uuidString)
            }
        }
    }
}
