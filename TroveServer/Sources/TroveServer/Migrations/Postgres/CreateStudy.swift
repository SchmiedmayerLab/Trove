//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent


struct CreateStudy: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("studies")
            .id()
            .field("draft_revision", .uuid, .required)
            .field("locales", .array(of: .string), .required)
            .field("icon", .string, .required)
            .field("details", .json, .required)
            .field("participation_criterion", .json, .required)
            .field("consent", .json, .required)
            .field("visibility", .string, .required)
            .field("enrollment_condition", .string, .required)
            .field("collection_configuration", .json, .required)
            .field(
                "group_id",
                .uuid,
                .required,
                .references("groups", "id", onDelete: .cascade)
            )
            .timestamps()
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("studies").delete()
    }
}
