//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import SQLKit


struct CreateComponents: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("components")
            .id()
            .field("study_id", .uuid, .required, .references("studies", "id", onDelete: .cascade))
            .field("data", .json, .required)
            .field("type", .string, .required)
            .field("name", .string, .required)
            .timestamps()
            .create()

        if let sql = database as? any SQLDatabase {
            try await sql.create(index: "idx_components_study_id")
                .on("components")
                .column("study_id")
                .run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("components").delete()
    }
}
