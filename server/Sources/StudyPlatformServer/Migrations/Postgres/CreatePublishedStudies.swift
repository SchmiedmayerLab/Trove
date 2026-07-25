//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent


struct CreatePublishedStudies: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("published_studies")
            .id()
            .field("study_id", .uuid, .required, .references("studies", "id", onDelete: .cascade))
            .field("revision", .int, .required)
            .field("visibility", .string, .required)
            .field("enrollment_condition", .string, .required)
            .field("metadata", .json, .required)
            .timestamps()
            .unique(on: "study_id", "revision")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("published_studies").delete()
    }
}
