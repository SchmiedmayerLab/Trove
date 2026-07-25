//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import SQLKit


struct CreateComponentSchedules: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("component_schedules")
            .id()
            .field("component_id", .uuid, .required, .references("components", "id", onDelete: .cascade))
            .field("schedule_data", .json, .required)
            .timestamps()
            .create()

        if let sql = database as? any SQLDatabase {
            try await sql.create(index: "idx_component_schedules_component_id")
                .on("component_schedules")
                .column("component_id")
                .run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("component_schedules").delete()
    }
}
