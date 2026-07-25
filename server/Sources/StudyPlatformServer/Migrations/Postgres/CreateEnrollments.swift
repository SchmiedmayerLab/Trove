//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import SQLKit


struct CreateEnrollments: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("enrollments")
            .id()
            .field("participant_id", .uuid, .required, .references("participants", "id", onDelete: .cascade))
            .field("study_id", .uuid, .required, .references("studies", "id", onDelete: .cascade))
            .field("invitation_code_id", .uuid, .references("invitation_codes", "id", onDelete: .setNull))
            .field("current_revision", .int, .required)
            .field("withdrawn_at", .datetime)
            .field("participation_data", .json, .required)
            .timestamps()
            .unique(on: "participant_id", "study_id")
            .unique(on: "invitation_code_id")
            .create()

        if let sql = database as? any SQLDatabase {
            try await sql.create(index: "idx_enrollments_study_id")
                .on("enrollments")
                .column("study_id")
                .run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("enrollments").delete()
    }
}
