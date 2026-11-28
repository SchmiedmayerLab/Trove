// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Fluent
import SQLKit


struct CreateStudyExports: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.transaction { transaction in
            try await transaction.schema("study_export_jobs")
                .id()
                .field("study_id", .uuid, .required, .references("studies", "id", onDelete: .restrict))
                .field("request_id", .uuid, .required)
                .field("membership", .data, .required)
                .unique(on: "study_id", "request_id")
                .create()
            try await transaction.schema("study_export_files")
                .field("id", .uuid, .identifier(auto: false), .references("study_export_jobs", "id", onDelete: .restrict))
                .field("manifest", .data, .required)
                .field("members", .data, .required)
                .field("ndjson", .data, .required)
                .create()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase, try await sql.raw("SELECT id FROM study_export_jobs LIMIT 1").all().isEmpty else {
                throw ServerError.conflict("Study export history must be retained")
            }
            try await transaction.schema("study_export_files").delete()
            try await transaction.schema("study_export_jobs").delete()
        }
    }
}
