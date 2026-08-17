//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import SQLKit


struct CreateInvitationCodes: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("invitation_codes")
            .id()
            .field("study_id", .uuid, .required, .references("studies", "id", onDelete: .cascade))
            .field("code", .string, .required)
            .field("expires_at", .datetime)
            .timestamps()
            .unique(on: "code")
            .create()

        if let sql = database as? any SQLDatabase {
            try await sql.create(index: "idx_invitation_codes_study_id")
                .on("invitation_codes")
                .column("study_id")
                .run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("invitation_codes").delete()
    }
}
