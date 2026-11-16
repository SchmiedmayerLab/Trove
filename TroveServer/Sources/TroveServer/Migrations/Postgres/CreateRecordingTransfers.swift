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


/// Declarations, attempts and receipts are append-only. Expiring object storage is a separate lifecycle.
struct CreateRecordingTransfers: AsyncMigration {
    enum RollbackError: Error { case retainedTransfers }

    static let tables = ["recording_transfers", "recording_transfer_attempts", "recording_transfer_receipts", "clinical_recording_attachments"]

    func prepare(on database: any Database) async throws {
        try await database.transaction { transaction in
            try await transaction.schema("recording_transfers")
                .id()
                .field("source_id", .uuid, .required, .references("source_bindings", "id", onDelete: .restrict))
                .field("transfer_id", .uuid, .required)
                .field("declaration", .string, .required, .sql(unsafeRaw: "CHECK (length(declaration) BETWEEN 1 AND 65536)"))
                .field("declaration_sha256", .string, .required, .sql(unsafeRaw: "CHECK (length(declaration_sha256) = 64)"))
                .field("created_at", .datetime, .required)
                .unique(on: "source_id", "transfer_id")
                .create()
            try await transaction.schema("recording_transfer_attempts")
                .field("artifact_id", .uuid, .identifier(auto: false), .references("stored_artifacts", "id", onDelete: .restrict))
                .field("transfer_row_id", .uuid, .required, .references("recording_transfers", "id", onDelete: .restrict))
                .field("attempt_number", .int, .required, .sql(unsafeRaw: "CHECK (attempt_number > 0)"))
                .field("lease_expires_at", .datetime, .required)
                .unique(on: "transfer_row_id", "attempt_number")
                .create()
            try await transaction.schema("recording_transfer_receipts")
                .field("artifact_id", .uuid, .identifier(auto: false), .references("recording_transfer_attempts", "artifact_id", onDelete: .restrict))
                .field("stored_byte_count", .int64, .required, .sql(unsafeRaw: "CHECK (stored_byte_count BETWEEN 1 AND 2147483647)"))
                .field("stored_sha256", .string, .required, .sql(unsafeRaw: "CHECK (length(stored_sha256) = 64)"))
                .field("verified_at", .datetime, .required)
                .field("expires_at", .datetime, .required, .sql(unsafeRaw: "CHECK (expires_at > verified_at)"))
                .create()
            try await transaction.schema("clinical_recording_attachments")
                .field("node_id", .uuid, .identifier(auto: false), .references("clinical_event_nodes", "id", onDelete: .restrict))
                .field("artifact_id", .uuid, .required, .references("recording_transfer_receipts", "artifact_id", onDelete: .restrict))
                .field("attachment_path", .string, .required, .sql(unsafeRaw: "CHECK (length(attachment_path) BETWEEN 1 AND 512)"))
                .field("content_evidence", .string, .required, .sql(unsafeRaw: "CHECK (length(content_evidence) BETWEEN 1 AND 1024)"))
                .create()
            guard let sql = transaction as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
            try await sql.raw("CREATE INDEX clinical_recording_artifact ON clinical_recording_attachments (artifact_id)").run()
            try await protect(on: transaction)
        }
    }

    private func protect(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        if database is any PostgresDatabase {
            try await sql.raw("""
                CREATE FUNCTION trove_reject_recording_transfer_mutation() RETURNS trigger AS $$
                BEGIN RAISE EXCEPTION 'Recording transfer evidence is append-only' USING ERRCODE = '23514'; END;
                $$ LANGUAGE plpgsql
                """)
                .run()
        }
        for table in Self.tables {
            if database is any PostgresDatabase {
                try await sql.raw("""
                    CREATE TRIGGER \(ident: table + "_no_mutation") BEFORE UPDATE OR DELETE OR TRUNCATE
                    ON \(ident: table) FOR EACH STATEMENT EXECUTE FUNCTION trove_reject_recording_transfer_mutation()
                    """)
                    .run()
            } else {
                for operation in ["UPDATE", "DELETE"] {
                    try await sql.raw("""
                        CREATE TRIGGER \(ident: table + "_no_" + operation.lowercased()) BEFORE \(unsafeRaw: operation) ON \(ident: table)
                        BEGIN SELECT RAISE(ABORT, 'Recording transfer evidence is append-only'); END
                        """)
                        .run()
                }
            }
        }
    }

    func revert(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
            if transaction is any PostgresDatabase {
                try await sql.raw("""
                    LOCK TABLE recording_transfers, recording_transfer_attempts, recording_transfer_receipts,
                        clinical_recording_attachments IN ACCESS EXCLUSIVE MODE
                    """)
                    .run()
            }
            let existing = try await sql.raw("SELECT id FROM recording_transfers LIMIT 1").first()
            guard existing == nil else {
                throw RollbackError.retainedTransfers
            }
            for table in Self.tables.reversed() { try await transaction.schema(table).delete() }
            if transaction is any PostgresDatabase {
                try await sql.raw("DROP FUNCTION trove_reject_recording_transfer_mutation()").run()
            }
        }
    }
}
