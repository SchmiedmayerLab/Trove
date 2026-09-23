//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Grove
import TroveAPIServer


final class ComponentService: Module, @unchecked Sendable {
    @Dependency(StudyService.self) var studyService

    func listComponents(studyId: UUID) async throws -> [Component] {
        try await studyService.readDraft(id: studyId) { _, transaction in
            try await ComponentRepository(database: transaction).findAll(studyId: studyId)
        }
    }

    func deleteComponent(studyId: UUID, componentId: UUID, expectedRevision: UUID) async throws {
        try await studyService.editDraft(id: studyId, expectedRevision: expectedRevision) { _, transaction in
            guard try await ComponentRepository(database: transaction).delete(id: componentId, studyId: studyId) else {
                throw ServerError.notFound(resource: "Component", identifier: componentId.uuidString)
            }
        }
    }

    func getComponent(studyId: UUID, id: UUID, expectedType: ComponentType) async throws -> Component {
        try await studyService.readDraft(id: studyId) { _, transaction in
            guard let component = try await ComponentRepository(database: transaction).find(id: id, studyId: studyId),
                  component.type == expectedType else {
                throw ServerError.notFound(resource: "Component", identifier: id.uuidString)
            }
            return component
        }
    }

    func createComponent(studyId: UUID, expectedRevision: UUID, name: String, data: ComponentData) async throws -> Component {
        try await studyService.editDraft(id: studyId, expectedRevision: expectedRevision) { _, transaction in
            try await ComponentRepository(database: transaction).create(Component(studyId: studyId, data: data, name: name))
        }
    }

    func replaceComponent(studyId: UUID, id: UUID, expectedRevision: UUID, name: String, data: ComponentData) async throws -> Component {
        try await studyService.editDraft(id: studyId, expectedRevision: expectedRevision) { _, transaction in
            let repository = ComponentRepository(database: transaction)
            guard let component = try await repository.find(id: id, studyId: studyId), component.type == data.type else {
                throw ServerError.notFound(resource: "Component", identifier: id.uuidString)
            }
            component.name = name
            component.data = data
            return try await repository.update(component)
        }
    }
}
