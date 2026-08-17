//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent


struct CreateEnrollmentConsents: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("enrollment_consents")
            .id()
            .field("enrollment_id", .uuid, .required, .references("enrollments", "id", onDelete: .cascade))
            .field("revision", .int, .required)
            .field("user_responses", .json, .required)
            .timestamps()
            .unique(on: "enrollment_id", "revision")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("enrollment_consents").delete()
    }
}
