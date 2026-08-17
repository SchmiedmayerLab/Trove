//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Grove
import GroveLocalization
import GroveStudyDefinition
import TroveAPIServer


final class ComponentService: Module, @unchecked Sendable {
    @Dependency(AuthorizationService.self) var authorizationService
    @Dependency(ComponentRepository.self) var componentRepository

    func listComponents(studyId: UUID) async throws -> [Component] {
        try await authorizationService.checkResearcherHasStudyAccess(studyId, role: .researcher)
        return try await componentRepository.findAll(studyId: studyId)
    }

    func deleteComponent(studyId: UUID, componentId: UUID) async throws {
        try await authorizationService.checkResearcherHasStudyAccess(studyId, role: .researcher)

        let deleted = try await componentRepository.delete(id: componentId, studyId: studyId)
        if !deleted {
            throw ServerError.notFound(resource: "Component", identifier: componentId.uuidString)
        }
    }

    // MARK: - Get Component

    func getComponent(studyId: UUID, id: UUID, expectedType: ComponentType) async throws -> Component {
        try await authorizationService.checkResearcherHasStudyAccess(studyId, role: .researcher)

        guard let component = try await componentRepository.find(id: id, studyId: studyId) else {
            throw ServerError.notFound(resource: "Component", identifier: id.uuidString)
        }

        guard component.type == expectedType else {
            throw ServerError.notFound(resource: "Component", identifier: id.uuidString)
        }

        return component
    }

    // MARK: - Create Component

    func createInformationalComponent(
        studyId: UUID,
        name: String,
        content: LocalizationsDictionary<InformationalContent>
    ) async throws -> Component {
        try await authorizationService.checkResearcherHasStudyAccess(studyId, role: .researcher)
        return try await componentRepository.create(Component(studyId: studyId, data: .informational(content), name: name))
    }

    func createQuestionnaireComponent(
        studyId: UUID,
        name: String,
        content: LocalizationsDictionary<QuestionnaireContent>
    ) async throws -> Component {
        try await authorizationService.checkResearcherHasStudyAccess(studyId, role: .researcher)
        return try await componentRepository.create(Component(studyId: studyId, data: .questionnaire(content), name: name))
    }

    func createHealthDataComponent(
        studyId: UUID,
        name: String,
        data: StudyDefinition.HealthDataCollectionComponent
    ) async throws -> Component {
        try await authorizationService.checkResearcherHasStudyAccess(studyId, role: .researcher)
        return try await componentRepository.create(Component(studyId: studyId, data: .healthDataCollection(data), name: name))
    }

    // MARK: - Update Component

    func updateInformationalComponent(
        studyId: UUID,
        id: UUID,
        name: String,
        content: LocalizationsDictionary<InformationalContent>
    ) async throws -> Component {
        let component = try await getComponent(studyId: studyId, id: id, expectedType: .informational)
        component.name = name
        component.data = .informational(content)
        return try await componentRepository.update(component)
    }

    func updateQuestionnaireComponent(
        studyId: UUID,
        id: UUID,
        name: String,
        content: LocalizationsDictionary<QuestionnaireContent>
    ) async throws -> Component {
        let component = try await getComponent(studyId: studyId, id: id, expectedType: .questionnaire)
        component.name = name
        component.data = .questionnaire(content)
        return try await componentRepository.update(component)
    }

    func updateHealthDataComponent(
        studyId: UUID,
        id: UUID,
        name: String,
        data: StudyDefinition.HealthDataCollectionComponent
    ) async throws -> Component {
        let component = try await getComponent(studyId: studyId, id: id, expectedType: .healthDataCollection)
        component.name = name
        component.data = .healthDataCollection(data)
        return try await componentRepository.update(component)
    }
}
