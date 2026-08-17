//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Grove
import GroveStudyDefinition


final class ComponentScheduleService: Module, @unchecked Sendable {
    @Dependency(AuthorizationService.self) var authorizationService
    @Dependency(ComponentRepository.self) var componentRepository
    @Dependency(ComponentScheduleRepository.self) var repository

    func listSchedules(studyId: UUID, componentId: UUID) async throws -> [ComponentSchedule] {
        try await authorizationService.checkResearcherHasStudyAccess(studyId, role: .researcher)
        try await requireSchedulableComponent(id: componentId, studyId: studyId)
        return try await repository.findAll(componentId: componentId)
    }

    func getSchedule(studyId: UUID, componentId: UUID, scheduleId: UUID) async throws -> ComponentSchedule {
        try await authorizationService.checkResearcherHasStudyAccess(studyId, role: .researcher)
        try await requireSchedulableComponent(id: componentId, studyId: studyId)

        guard let schedule = try await repository.find(id: scheduleId, componentId: componentId) else {
            throw ServerError.notFound(resource: "ComponentSchedule", identifier: scheduleId.uuidString)
        }

        return schedule
    }

    func createSchedule(
        studyId: UUID,
        componentId: UUID,
        data: StudyDefinition.ComponentSchedule
    ) async throws -> ComponentSchedule {
        try await authorizationService.checkResearcherHasStudyAccess(studyId, role: .researcher)
        try await requireSchedulableComponent(id: componentId, studyId: studyId)

        let schedule = ComponentSchedule(componentId: componentId, scheduleData: data)
        return try await repository.create(schedule)
    }

    func replaceSchedule(
        studyId: UUID,
        componentId: UUID,
        scheduleId: UUID,
        data: StudyDefinition.ComponentSchedule
    ) async throws -> ComponentSchedule {
        try await authorizationService.checkResearcherHasStudyAccess(studyId, role: .researcher)
        try await requireSchedulableComponent(id: componentId, studyId: studyId)

        guard let schedule = try await repository.find(id: scheduleId, componentId: componentId) else {
            throw ServerError.notFound(resource: "ComponentSchedule", identifier: scheduleId.uuidString)
        }

        schedule.scheduleData = data
        return try await repository.update(schedule)
    }

    func deleteSchedule(studyId: UUID, componentId: UUID, scheduleId: UUID) async throws {
        try await authorizationService.checkResearcherHasStudyAccess(studyId, role: .researcher)
        try await requireSchedulableComponent(id: componentId, studyId: studyId)

        let deleted = try await repository.delete(id: scheduleId, componentId: componentId)
        if !deleted {
            throw ServerError.notFound(resource: "ComponentSchedule", identifier: scheduleId.uuidString)
        }
    }

    @discardableResult
    private func requireSchedulableComponent(id: UUID, studyId: UUID) async throws -> Component {
        guard let component = try await componentRepository.find(id: id, studyId: studyId) else {
            throw ServerError.notFound(resource: "Component", identifier: id.uuidString)
        }
        guard component.type.supportsSchedules else {
            throw ServerError.conflict("Component type '\(component.type.rawValue)' does not support schedules")
        }
        return component
    }
}
