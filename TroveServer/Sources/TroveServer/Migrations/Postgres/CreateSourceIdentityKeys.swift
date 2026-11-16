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


/// Immutable identity commitments and append-only encryption envelopes. Rotation does not replace identity evidence.
struct CreateSourceIdentityKeys: AsyncMigration {
    enum RollbackError: Error { case retainedIdentity }

    static let tables = ["source_identity_keys", "source_identity_key_envelopes"]

    func prepare(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
            try await transaction.schema("source_identity_keys")
                .field("source_id", .uuid, .required)
                .compositeIdentifier(over: "source_id")
                .field("participant_id", .uuid, .required)
                .field("key_id", .uuid, .required)
                .field("epoch", .string, .required, .sql(unsafeRaw: "CHECK (length(epoch) BETWEEN 1 AND 32)"))
                .field("identifier_root", .string, .required, ClinicalRecordSchema.identity("identifier_root", on: transaction))
                .field("repository_system", .string, .required, ClinicalRecordSchema.identity("repository_system", on: transaction))
                .field("repository_value", .string, .required, ClinicalRecordSchema.identity("repository_value", on: transaction))
                .field("key_sha256", .data, .required, .sql(unsafeRaw: "CHECK (length(key_sha256) = 32)"))
                .field("created_at", .datetime, .required)
                .foreignKey(
                    ["source_id", "participant_id"],
                    references: "source_bindings",
                    ["id", "participant_id"],
                    onDelete: .restrict,
                    name: "source_identity_owner_fk"
                )
                .create()
            try await transaction.schema("source_identity_key_envelopes")
                .field("source_id", .uuid, .required, .references("source_identity_keys", "source_id", onDelete: .restrict))
                .field("encryption_key_id", .string, .required, .sql(unsafeRaw: "CHECK (length(encryption_key_id) BETWEEN 1 AND 64)"))
                .field("version", .int, .required, .sql(unsafeRaw: "CHECK (version = 1)"))
                .field("sealed_key", .data, .required, .sql(unsafeRaw: "CHECK (length(sealed_key) = 60)"))
                .field("sequence", .int64, .required, .sql(unsafeRaw: "CHECK (sequence > 0)"))
                .field("created_at", .datetime, .required)
                .compositeIdentifier(over: "source_id", "encryption_key_id")
                .unique(on: "source_id", "sequence")
                .create()
            try await protect(on: sql, postgres: transaction is any PostgresDatabase)
        }
    }

    func revert(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
            if transaction is any PostgresDatabase {
                try await sql.raw("LOCK TABLE source_identity_keys, source_identity_key_envelopes IN ACCESS EXCLUSIVE MODE").run()
            }
            let row = try await sql.raw("SELECT COUNT(*) AS count FROM source_identity_keys").first()
            guard let row, try row.decode(column: "count", as: Int.self) == 0 else { throw RollbackError.retainedIdentity }
            for table in Self.tables.reversed() { try await transaction.schema(table).delete() }
            if transaction is any PostgresDatabase {
                try await sql.raw("DROP FUNCTION trove_reject_source_identity_mutation()").run()
            }
        }
    }

    private func protect(on sql: any SQLDatabase, postgres: Bool) async throws {
        if postgres {
            try await sql.raw("""
                CREATE FUNCTION trove_reject_source_identity_mutation() RETURNS trigger AS $$
                BEGIN RAISE EXCEPTION 'Source identity history is append-only' USING ERRCODE = '23514'; END;
                $$ LANGUAGE plpgsql
                """)
                .run()
        }
        for table in Self.tables {
            if postgres {
                try await sql.raw("""
                    CREATE TRIGGER \(ident: table + "_no_mutation") BEFORE UPDATE OR DELETE OR TRUNCATE
                    ON \(ident: table) FOR EACH STATEMENT EXECUTE FUNCTION trove_reject_source_identity_mutation()
                    """)
                    .run()
            } else {
                for operation in ["UPDATE", "DELETE"] {
                    try await sql.raw("""
                        CREATE TRIGGER \(ident: table + "_no_" + operation.lowercased()) BEFORE \(unsafeRaw: operation) ON \(ident: table)
                        BEGIN SELECT RAISE(ABORT, 'Source identity history is append-only'); END
                        """)
                        .run()
                }
            }
        }
    }
}
