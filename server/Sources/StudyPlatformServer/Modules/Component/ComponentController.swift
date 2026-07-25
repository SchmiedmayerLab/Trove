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
    // MARK: - List / Delete

    func getStudiesStudyIdComponents(
        _ input: Operations.GetStudiesStudyIdComponents.Input
    ) async throws -> Operations.GetStudiesStudyIdComponents.Output {
        let studyId = try input.path.studyId.requireId()
        let components = try await componentService.listComponents(studyId: studyId)
        return .ok(.init(body: .json(try components.map { try Components.Schemas.Component($0) })))
    }

    func deleteStudiesStudyIdComponentsComponentId(
        _ input: Operations.DeleteStudiesStudyIdComponentsComponentId.Input
    ) async throws -> Operations.DeleteStudiesStudyIdComponentsComponentId.Output {
        let studyId = try input.path.studyId.requireId()
        let componentId = try input.path.componentId.requireId()
        try await componentService.deleteComponent(studyId: studyId, componentId: componentId)
        return .noContent(.init())
    }

    // MARK: - Informational

    func postStudiesStudyIdComponentsInformational(
        _ input: Operations.PostStudiesStudyIdComponentsInformational.Input
    ) async throws -> Operations.PostStudiesStudyIdComponentsInformational.Output {
        let studyId = try input.path.studyId.requireId()
        guard case .json(let schema) = input.body else {
            throw ServerError.jsonBodyRequired
        }

        let component = try await componentService.createInformationalComponent(
            studyId: studyId,
            name: schema.name,
            content: schema.data
        )

        return .created(.init(body: .json(try .init(component))))
    }

    func getStudiesStudyIdComponentsInformationalComponentId(
        _ input: Operations.GetStudiesStudyIdComponentsInformationalComponentId.Input
    ) async throws -> Operations.GetStudiesStudyIdComponentsInformationalComponentId.Output {
        let studyId = try input.path.studyId.requireId()
        let componentId = try input.path.componentId.requireId()

        let component = try await componentService.getComponent(
            studyId: studyId,
            id: componentId,
            expectedType: .informational
        )

        return .ok(.init(body: .json(try .init(component))))
    }

    func putStudiesStudyIdComponentsInformationalComponentId(
        _ input: Operations.PutStudiesStudyIdComponentsInformationalComponentId.Input
    ) async throws -> Operations.PutStudiesStudyIdComponentsInformationalComponentId.Output {
        let studyId = try input.path.studyId.requireId()
        let componentId = try input.path.componentId.requireId()

        guard case .json(let schema) = input.body else {
            throw ServerError.jsonBodyRequired
        }

        let component = try await componentService.updateInformationalComponent(
            studyId: studyId,
            id: componentId,
            name: schema.name,
            content: schema.data
        )

        return .ok(.init(body: .json(try .init(component))))
    }

    // MARK: - Questionnaire

    func postStudiesStudyIdComponentsQuestionnaire(
        _ input: Operations.PostStudiesStudyIdComponentsQuestionnaire.Input
    ) async throws -> Operations.PostStudiesStudyIdComponentsQuestionnaire.Output {
        let studyId = try input.path.studyId.requireId()
        guard case .json(let schema) = input.body else {
            throw ServerError.jsonBodyRequired
        }

        let component = try await componentService.createQuestionnaireComponent(
            studyId: studyId,
            name: schema.name,
            content: schema.data
        )

        return .created(.init(body: .json(try .init(component))))
    }

    func getStudiesStudyIdComponentsQuestionnaireComponentId(
        _ input: Operations.GetStudiesStudyIdComponentsQuestionnaireComponentId.Input
    ) async throws -> Operations.GetStudiesStudyIdComponentsQuestionnaireComponentId.Output {
        let studyId = try input.path.studyId.requireId()
        let componentId = try input.path.componentId.requireId()

        let component = try await componentService.getComponent(
            studyId: studyId,
            id: componentId,
            expectedType: .questionnaire
        )

        return .ok(.init(body: .json(try .init(component))))
    }

    func putStudiesStudyIdComponentsQuestionnaireComponentId(
        _ input: Operations.PutStudiesStudyIdComponentsQuestionnaireComponentId.Input
    ) async throws -> Operations.PutStudiesStudyIdComponentsQuestionnaireComponentId.Output {
        let studyId = try input.path.studyId.requireId()
        let componentId = try input.path.componentId.requireId()

        guard case .json(let schema) = input.body else {
            throw ServerError.jsonBodyRequired
        }

        let component = try await componentService.updateQuestionnaireComponent(
            studyId: studyId,
            id: componentId,
            name: schema.name,
            content: schema.data
        )

        return .ok(.init(body: .json(try .init(component))))
    }

    // MARK: - Health Data

    func postStudiesStudyIdComponentsHealthData(
        _ input: Operations.PostStudiesStudyIdComponentsHealthData.Input
    ) async throws -> Operations.PostStudiesStudyIdComponentsHealthData.Output {
        let studyId = try input.path.studyId.requireId()
        guard case .json(let schema) = input.body else {
            throw ServerError.jsonBodyRequired
        }

        let data = StudyDefinition.HealthDataCollectionComponent(schema.data)

        let component = try await componentService.createHealthDataComponent(
            studyId: studyId,
            name: schema.name,
            data: data
        )

        return .created(.init(body: .json(try .init(component))))
    }

    func getStudiesStudyIdComponentsHealthDataComponentId(
        _ input: Operations.GetStudiesStudyIdComponentsHealthDataComponentId.Input
    ) async throws -> Operations.GetStudiesStudyIdComponentsHealthDataComponentId.Output {
        let studyId = try input.path.studyId.requireId()
        let componentId = try input.path.componentId.requireId()

        let component = try await componentService.getComponent(
            studyId: studyId,
            id: componentId,
            expectedType: .healthDataCollection
        )

        return .ok(.init(body: .json(try .init(component))))
    }

    func putStudiesStudyIdComponentsHealthDataComponentId(
        _ input: Operations.PutStudiesStudyIdComponentsHealthDataComponentId.Input
    ) async throws -> Operations.PutStudiesStudyIdComponentsHealthDataComponentId.Output {
        let studyId = try input.path.studyId.requireId()
        let componentId = try input.path.componentId.requireId()

        guard case .json(let schema) = input.body else {
            throw ServerError.jsonBodyRequired
        }

        let data = StudyDefinition.HealthDataCollectionComponent(schema.data)

        let component = try await componentService.updateHealthDataComponent(
            studyId: studyId,
            id: componentId,
            name: schema.name,
            data: data
        )

        return .ok(.init(body: .json(try .init(component))))
    }
}
