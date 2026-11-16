//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import FluentPostgresDriver
import FluentSQL
import SQLKit


struct CreateSourceInstallations: AsyncMigration {
    enum RollbackError: Error { case retainedInstallation }

    func prepare(on database: any Database) async throws {
        try await database.transaction { transaction in
            try await transaction.schema("source_installations")
                .field("participant_id", .uuid, .required)
                .field("source_id", .uuid, .required)
                .field("registration_id", .uuid, .required)
                .field("credential_verifier", .data, .required, .sql(unsafeRaw: "CHECK (length(credential_verifier) = 32)"))
                .field("created_at", .datetime, .required)
                .field("revoked_at", .datetime, .sql(unsafeRaw: "CHECK (revoked_at IS NULL OR revoked_at >= created_at)"))
                .compositeIdentifier(over: "participant_id", "registration_id")
                .foreignKey(
                    ["source_id", "participant_id"],
                    references: "source_bindings",
                    ["id", "participant_id"],
                    onDelete: .restrict,
                    name: "source_installation_owner_fk"
                )
                .create()
            try await RevocableSourceSchema.protect(
                table: "source_installations",
                immutableColumns: ["participant_id", "source_id", "registration_id", "credential_verifier", "created_at"],
                on: transaction
            )
        }
    }

    func revert(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
            if transaction is any PostgresDatabase {
                try await sql.raw("LOCK TABLE source_installations IN ACCESS EXCLUSIVE MODE").run()
            }
            let row = try await sql.raw("SELECT COUNT(*) AS count FROM source_installations").first()
            guard let row, try row.decode(column: "count", as: Int.self) == 0 else { throw RollbackError.retainedInstallation }
            try await transaction.schema("source_installations").delete()
            if transaction is any PostgresDatabase, let sql = transaction as? any SQLDatabase {
                try await sql.raw("DROP FUNCTION trove_protect_source_installations()").run()
            }
        }
    }
}
