//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SpeziStudyDefinition
import StudyPlatformAPIServer


extension Controller {
    func getStudiesStudyIdComponentsComponentIdSchedules(
        _ input: Operations.GetStudiesStudyIdComponentsComponentIdSchedules.Input
    ) async throws -> Operations.GetStudiesStudyIdComponentsComponentIdSchedules.Output {
        let studyId = try input.path.studyId.requireId()
        let componentId = try input.path.componentId.requireId()

        let schedules = try await componentScheduleService.listSchedules(studyId: studyId, componentId: componentId)
        return .ok(.init(body: .json(try schedules.map { try .init($0) })))
    }

    func postStudiesStudyIdComponentsComponentIdSchedules(
        _ input: Operations.PostStudiesStudyIdComponentsComponentIdSchedules.Input
    ) async throws -> Operations.PostStudiesStudyIdComponentsComponentIdSchedules.Output {
        let studyId = try input.path.studyId.requireId()
        let componentId = try input.path.componentId.requireId()

        guard case .json(let schema) = input.body else {
            throw ServerError.jsonBodyRequired
        }

        let data = try StudyDefinition.ComponentSchedule(id: UUID(), componentId: componentId, schema)
        let schedule = try await componentScheduleService.createSchedule(studyId: studyId, componentId: componentId, data: data)

        return .created(.init(body: .json(try .init(schedule))))
    }

    func getStudiesStudyIdComponentsComponentIdSchedulesScheduleId(
        _ input: Operations.GetStudiesStudyIdComponentsComponentIdSchedulesScheduleId.Input
    ) async throws -> Operations.GetStudiesStudyIdComponentsComponentIdSchedulesScheduleId.Output {
        let studyId = try input.path.studyId.requireId()
        let componentId = try input.path.componentId.requireId()
        let scheduleId = try input.path.scheduleId.requireId()

        let schedule = try await componentScheduleService.getSchedule(studyId: studyId, componentId: componentId, scheduleId: scheduleId)

        return .ok(.init(body: .json(try .init(schedule))))
    }

    func putStudiesStudyIdComponentsComponentIdSchedulesScheduleId(
        _ input: Operations.PutStudiesStudyIdComponentsComponentIdSchedulesScheduleId.Input
    ) async throws -> Operations.PutStudiesStudyIdComponentsComponentIdSchedulesScheduleId.Output {
        let studyId = try input.path.studyId.requireId()
        let componentId = try input.path.componentId.requireId()
        let scheduleId = try input.path.scheduleId.requireId()

        guard case .json(let schema) = input.body else {
            throw ServerError.jsonBodyRequired
        }

        let data = try StudyDefinition.ComponentSchedule(id: scheduleId, componentId: componentId, schema)
        let schedule = try await componentScheduleService.replaceSchedule(
            studyId: studyId,
            componentId: componentId,
            scheduleId: scheduleId,
            data: data
        )

        return .ok(.init(body: .json(try .init(schedule))))
    }

    func deleteStudiesStudyIdComponentsComponentIdSchedulesScheduleId(
        _ input: Operations.DeleteStudiesStudyIdComponentsComponentIdSchedulesScheduleId.Input
    ) async throws -> Operations.DeleteStudiesStudyIdComponentsComponentIdSchedulesScheduleId.Output {
        let studyId = try input.path.studyId.requireId()
        let componentId = try input.path.componentId.requireId()
        let scheduleId = try input.path.scheduleId.requireId()

        try await componentScheduleService.deleteSchedule(studyId: studyId, componentId: componentId, scheduleId: scheduleId)

        return .noContent(.init())
    }
}
