//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import FluentPostgresDriver
import SQLKit


struct CreateSourceBindings: AsyncMigration {
    private static func protect(on transaction: any Database) async throws {
        guard let sql = transaction as? any SQLDatabase else {
            throw AuditError.unsupportedDatabase
        }
        try await sql.raw("""
            CREATE UNIQUE INDEX source_bindings_native_repository
            ON source_bindings (participant_id, repository_kind) WHERE kind = 'participant-app'
            """)
            .run()
        try await RevocableSourceSchema.protect(
            table: "source_bindings",
            immutableColumns: [
                "id", "participant_id", "key_id", "key_epoch", "repository_kind", "kind", "provider_registration_id",
                "identifier_root", "event_identifier_system",
                "participant_identifier_system", "participant_identifier_value", "created_at"
            ],
            on: transaction
        )
    }

    func prepare(on database: any Database) async throws {
        try await database.transaction { transaction in
            try await transaction.schema("source_bindings")
                .id()
                .field("participant_id", .uuid, .required, .references("participants", "id", onDelete: .restrict))
                .field("key_id", .uuid, .required)
                .field("key_epoch", .string, .required)
                .field("repository_kind", .string, .required)
                .field("kind", .string, .required)
                .field("provider_registration_id", .uuid, .references("provider_registrations", "id", onDelete: .restrict))
                .field("identifier_root", .string, .required)
                .field("event_identifier_system", .string, .required)
                .field("participant_identifier_system", .string, .required)
                .field("participant_identifier_value", .string, .required)
                .field("created_at", .datetime, .required)
                .field("revoked_at", .datetime)
                .unique(on: "key_id")
                .unique(on: "event_identifier_system")
                .unique(on: "identifier_root")
                .unique(on: "id", "participant_id", name: "source_participant_identity")
                .constraint(.custom(SQLConstraint(algorithm: SQLTableConstraintAlgorithm.check(SQLRaw("""
                    ((kind = 'participant-app' AND repository_kind IN ('healthkit', 'sensorkit') AND provider_registration_id IS NULL)
                        OR (kind = 'server-worker' AND repository_kind IN ('withings', 'oura', 'google-health-api')
                            AND provider_registration_id IS NOT NULL)) AND key_epoch = '1'
                    AND length(event_identifier_system) > 0 AND length(identifier_root) BETWEEN 1 AND 256
                    AND length(participant_identifier_system) > 0 AND length(participant_identifier_value) > 0
                    AND (revoked_at IS NULL OR revoked_at >= created_at)
                    """)))))
                .create()
            try await Self.protect(on: transaction)
        }
    }

    func revert(on database: any Database) async throws {
        try await database.transaction { transaction in
            try await transaction.schema("source_bindings").delete()
            if transaction is any PostgresDatabase, let sql = transaction as? any SQLDatabase {
                try await sql.raw("DROP FUNCTION trove_protect_source_bindings()").run()
            }
        }
    }
}
