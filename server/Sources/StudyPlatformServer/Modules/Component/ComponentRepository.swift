//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import Spezi


final class ComponentRepository: Module, Sendable {
    let database: any Database

    init(database: any Database) {
        self.database = database
    }

    func findAll(studyId: UUID) async throws -> [Component] {
        try await Component.query(on: database)
            .filter(\.$study.$id == studyId)
            .all()
    }

    func find(id: UUID, studyId: UUID) async throws -> Component? {
        // swiftlint:disable:next first_where
        try await Component.query(on: database)
            .filter(\.$id == id)
            .filter(\.$study.$id == studyId)
            .first()
    }

    func create(_ component: Component) async throws -> Component {
        let id = UUID()
        component.id = id
        component.type = component.data.type
        if case .healthDataCollection(var healthData) = component.data {
            healthData.id = id
            component.data = .healthDataCollection(healthData)
        }
        try await component.save(on: database)
        return component
    }

    func update(_ component: Component) async throws -> Component {
        component.type = component.data.type
        if case .healthDataCollection(var healthData) = component.data {
            healthData.id = try component.requireId()
            component.data = .healthDataCollection(healthData)
        }
        try await component.update(on: database)
        return component
    }

    func delete(id: UUID, studyId: UUID) async throws -> Bool {
        guard let component = try await find(id: id, studyId: studyId) else {
            return false
        }
        try await component.delete(on: database)
        return true
    }
}
