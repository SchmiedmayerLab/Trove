//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import FluentSQL


struct CreateParticipants: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("participants")
            .id()
            .field("identity_provider_issuer", .string, .required, .sql(unsafeRaw: "CHECK (length(identity_provider_issuer) > 0)"))
            .field("identity_provider_id", .string, .required, .sql(unsafeRaw: "CHECK (length(identity_provider_id) > 0)"))
            .field("first_name", .string, .required)
            .field("last_name", .string, .required)
            .field("email", .string, .required)
            .field(
                "gender",
                .string,
                .required,
                .sql(unsafeRaw: "CHECK (gender IN ('female', 'male', 'transgender', 'nonBinary', 'preferNotToState'))")
            )
            .field("date_of_birth", .date, .required)
            .field("region", .string, .required)
            .field("language", .string, .required)
            .field("phone_number", .string, .required)
            .timestamps()
            .unique(on: "identity_provider_issuer", "identity_provider_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("participants").delete()
    }
}
