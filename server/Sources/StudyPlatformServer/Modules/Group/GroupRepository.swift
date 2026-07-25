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


final class GroupRepository: Module, Sendable {
    let database: any Database

    init(database: any Database) {
        self.database = database
    }

    func find(id: UUID) async throws -> Group? {
        try await Group.find(id, on: database)
    }

    func listAll() async throws -> [Group] {
        try await Group.query(on: database).all()
    }

    func findByNames(_ names: [String]) async throws -> [Group] {
        try await Group.query(on: database).filter(\.$name ~~ names).all()
    }

    @discardableResult
    func create(_ group: Group) async throws -> Group {
        try await group.save(on: database)
        return group
    }

    func update(_ group: Group) async throws -> Group {
        try await group.update(on: database)
        return group
    }

    func delete(id: UUID) async throws -> Bool {
        guard let group = try await Group.find(id, on: database) else {
            return false
        }

        try await group.delete(on: database)
        return true
    }
}
