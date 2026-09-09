//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import FluentSQL
import SQLKit


struct CreateEnrollments: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.transaction { transaction in
            try await transaction.schema("enrollments")
                .id()
                .field("participant_id", .uuid, .required, .references("participants", "id", onDelete: .restrict))
                .field("study_id", .uuid, .required, .references("studies", "id", onDelete: .restrict))
                .field("invitation_code_id", .uuid, .references("invitation_codes", "id", onDelete: .restrict))
                .field("current_revision", .int, .required, .sql(unsafeRaw: "CHECK (current_revision > 0)"))
                .field("state_version", .int64, .required, .sql(.default(SQLLiteral.numeric("1"))), .sql(unsafeRaw: "CHECK (state_version > 0)"))
                .field("withdrawn_at", .datetime)
                .field("participation_data", .json, .required)
                .timestamps()
                .unique(on: "participant_id", "study_id")
                .unique(on: "invitation_code_id")
                .unique(on: "id", "study_id", name: "enrollment_study_identity")
                .unique(on: "id", "study_id", "participant_id", name: "enrollment_study_participant_identity")
                .create()

            guard let sql = transaction as? any SQLDatabase else { throw ArtifactStore.Failure.unsupportedDatabase }
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
