//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent


struct CreateProviderRegistrations: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("provider_registrations")
            .id()
            .field("configuration", .string, .required, .sql(unsafeRaw: "CHECK (length(configuration) BETWEEN 1 AND 131072)"))
            .field("generation", .int64, .required, .sql(unsafeRaw: "CHECK (generation > 0)"))
            .field("approved", .bool, .required)
            .field("updated_at", .datetime, .required)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("provider_registrations").delete()
    }
}
