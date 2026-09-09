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


struct CreateEnrollmentConsents: AsyncMigration {
    enum RollbackError: Error, Equatable { case retainedEvidence }

    func prepare(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw ArtifactStore.Failure.unsupportedDatabase }
            let digestConstraint = transaction is any PostgresDatabase
                ? "CHECK (length(evidence_digest) = 64 AND evidence_digest ~ '^[0-9a-f]{64}$')"
                : "CHECK (length(evidence_digest) = 64 AND evidence_digest NOT GLOB '*[^0-9a-f]*')"
            try await transaction.schema("enrollment_consents")
                .id()
                .field("enrollment_id", .uuid, .required, .references("enrollments", "id", onDelete: .restrict))
                .field("revision", .int, .required, .sql(unsafeRaw: "CHECK (revision > 0)"))
                .field("user_responses", .json, .required)
                .field("evidence_key", .string, .required, .sql(unsafeRaw: "CHECK (length(evidence_key) BETWEEN 1 AND 1024)"))
                .field("evidence_digest", .string, .required, .sql(unsafeRaw: digestConstraint))
                .field("presentation_proof", .json, .required)
                .field("command_id", .uuid, .required)
                .field("expected_enrollment_version", .int64, .required, .sql(unsafeRaw: "CHECK (expected_enrollment_version > 0)"))
                .field(
                    "accepted_enrollment_version",
                    .int64,
                    .required,
                    .sql(unsafeRaw: """
                        CHECK (accepted_enrollment_version > expected_enrollment_version
                            AND accepted_enrollment_version - 1 = expected_enrollment_version)
                        """)
                )
                .field("artifact_id", .uuid, .required, .references(StoredArtifact.schema, "id", onDelete: .restrict))
                .timestamps()
                .unique(on: "enrollment_id", "revision")
                .unique(on: "enrollment_id", "accepted_enrollment_version")
                .unique(on: "id", "enrollment_id", "revision", name: "enrollment_consent_identity")
                .create()
            try await sql.raw("CREATE UNIQUE INDEX enrollment_consent_command ON enrollment_consents (enrollment_id, command_id)").run()
            try await sql.raw("CREATE INDEX consent_artifact_reference ON enrollment_consents (artifact_id)").run()
            try await protectRecords(on: transaction, sql: sql)
        }
    }

    func revert(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw ArtifactStore.Failure.unsupportedDatabase }
            if transaction is any PostgresDatabase {
                try await sql.raw("LOCK TABLE enrollment_consents IN ACCESS EXCLUSIVE MODE").run()
            }
            let row = try await sql.raw("SELECT COUNT(*) AS count FROM enrollment_consents").first()
            guard let row, try row.decode(column: "count", as: Int.self) == 0 else {
                throw RollbackError.retainedEvidence
            }
            try await transaction.schema("enrollment_consents").delete()
            if transaction is any PostgresDatabase {
                try await sql.raw("DROP FUNCTION trove_reject_enrollment_consents_mutation()").run()
            }
        }
    }

    private func protectRecords(on database: any Database, sql: any SQLDatabase) async throws {
        if database is any PostgresDatabase {
            try await sql.raw("""
                CREATE FUNCTION trove_reject_enrollment_consents_mutation() RETURNS trigger AS $$
                BEGIN
                    RAISE EXCEPTION 'Accepted evidence is append-only' USING ERRCODE = '23514';
                END;
                $$ LANGUAGE plpgsql
                """)
                .run()
            try await sql.raw("""
                CREATE TRIGGER enrollment_consents_no_mutation BEFORE UPDATE OR DELETE OR TRUNCATE
                ON enrollment_consents FOR EACH STATEMENT EXECUTE FUNCTION trove_reject_enrollment_consents_mutation()
                """)
                .run()
        } else {
            try await sql.raw("""
                CREATE TRIGGER enrollment_consents_no_update BEFORE UPDATE ON enrollment_consents
                BEGIN SELECT RAISE(ABORT, 'Accepted evidence is append-only'); END
                """)
                .run()
            try await sql.raw("""
                CREATE TRIGGER enrollment_consents_no_delete BEFORE DELETE ON enrollment_consents
                BEGIN SELECT RAISE(ABORT, 'Accepted evidence is append-only'); END
                """)
                .run()
        }
    }
}
