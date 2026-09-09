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


struct CreatePublishedStudies: AsyncMigration {
    enum RollbackError: Error, Equatable { case retainedEvidence }

    func prepare(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw ArtifactStore.Failure.unsupportedDatabase }
            let digestConstraint = transaction is any PostgresDatabase
                ? "CHECK (length(bundle_digest) = 64 AND bundle_digest ~ '^[0-9a-f]{64}$')"
                : "CHECK (length(bundle_digest) = 64 AND bundle_digest NOT GLOB '*[^0-9a-f]*')"
            try await transaction.schema("published_studies")
                .id()
                .field("study_id", .uuid, .required, .references("studies", "id", onDelete: .restrict))
                .field("revision", .int, .required, .sql(unsafeRaw: "CHECK (revision > 0)"))
                .field("visibility", .string, .required)
                .field("enrollment_condition", .string, .required)
                .field("metadata", .json, .required)
                .field("bundle_key", .string, .required, .sql(unsafeRaw: "CHECK (length(bundle_key) BETWEEN 1 AND 1024)"))
                .field("bundle_digest", .string, .required, .sql(unsafeRaw: digestConstraint))
                .field("consent_snapshot", .json, .required)
                .field("collection_policy", .json, .required)
                .field("artifact_id", .uuid, .required, .references(StoredArtifact.schema, "id", onDelete: .restrict))
                .timestamps()
                .unique(on: "study_id", "revision")
                .unique(on: "id", "study_id", "revision", name: "published_study_identity")
                .create()
            try await sql.raw("CREATE INDEX publication_artifact_reference ON published_studies (artifact_id)").run()
            try await protectRecords(on: transaction, sql: sql)
        }
    }

    func revert(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw ArtifactStore.Failure.unsupportedDatabase }
            if transaction is any PostgresDatabase {
                try await sql.raw("LOCK TABLE published_studies IN ACCESS EXCLUSIVE MODE").run()
            }
            let row = try await sql.raw("SELECT COUNT(*) AS count FROM published_studies").first()
            guard let row, try row.decode(column: "count", as: Int.self) == 0 else {
                throw RollbackError.retainedEvidence
            }
            try await transaction.schema("published_studies").delete()
            if transaction is any PostgresDatabase {
                try await sql.raw("DROP FUNCTION trove_reject_published_studies_mutation()").run()
            }
        }
    }

    private func protectRecords(on database: any Database, sql: any SQLDatabase) async throws {
        if database is any PostgresDatabase {
            try await sql.raw("""
                CREATE FUNCTION trove_reject_published_studies_mutation() RETURNS trigger AS $$
                BEGIN
                    RAISE EXCEPTION 'Accepted evidence is append-only' USING ERRCODE = '23514';
                END;
                $$ LANGUAGE plpgsql
                """)
                .run()
            try await sql.raw("""
                CREATE TRIGGER published_studies_no_mutation BEFORE UPDATE OR DELETE OR TRUNCATE
                ON published_studies FOR EACH STATEMENT EXECUTE FUNCTION trove_reject_published_studies_mutation()
                """)
                .run()
        } else {
            try await sql.raw("""
                CREATE TRIGGER published_studies_no_update BEFORE UPDATE ON published_studies
                BEGIN SELECT RAISE(ABORT, 'Accepted evidence is append-only'); END
                """)
                .run()
            try await sql.raw("""
                CREATE TRIGGER published_studies_no_delete BEFORE DELETE ON published_studies
                BEGIN SELECT RAISE(ABORT, 'Accepted evidence is append-only'); END
                """)
                .run()
        }
    }
}
