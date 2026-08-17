//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent


struct CreateGroups: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("groups")
            .id()
            .field("name", .string, .required)
            .field("icon", .string, .required)
            .unique(on: "name")
            .timestamps()
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("groups").delete()
    }
}
