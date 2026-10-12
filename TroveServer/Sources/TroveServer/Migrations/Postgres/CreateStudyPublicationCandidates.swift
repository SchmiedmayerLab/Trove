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


struct CreateStudyPublicationCandidates: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.transaction { transaction in
            try await self.createSchema(on: transaction)
            try await self.protectEvidence(on: transaction)
        }
    }

    private func createSchema(on database: any Database) async throws {
        try await database.schema(StudyPublicationCandidate.schema)
            .id()
            .field("study_id", .uuid, .required, .references("studies", "id", onDelete: .cascade))
            .field("group_id", .uuid, .required, .references("groups", "id", onDelete: .restrict))
            .field("draft_revision", .uuid, .required)
            .field("publication_revision", .int, .required, .sql(unsafeRaw: "CHECK (publication_revision > 0)"))
            .field("artifact_id", .uuid, .required, .references(StoredArtifact.schema, "id", onDelete: .restrict))
            .field("bundle_digest", .string, .required, .sql(unsafeRaw: "CHECK (length(bundle_digest) = 64)"))
            .field("byte_count", .int, .required, .sql(unsafeRaw: "CHECK (byte_count BETWEEN 1 AND 52428800)"))
            .field("validator_identity", .string, .required)
            .field("contract_revision", .string, .required)
            .field("execution_capability", .string, .required)
            .field("snapshot", .json, .required)
            .field("created_at", .datetime, .required)
            .field("expires_at", .datetime, .required)
            .constraint(.custom(SQLConstraint(
                algorithm: SQLTableConstraintAlgorithm.check(SQLRaw("expires_at > created_at")),
                name: SQLIdentifier("study_publication_candidate_lifetime")
            )))
            .unique(on: "artifact_id")
            .create()
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        try await sql.raw("CREATE INDEX study_publication_candidate_scope ON study_publication_candidates (study_id, expires_at)").run()
    }

    private func protectEvidence(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        // Pending evidence may expire, but it must never be rewritten under a reviewed ID.
        if database is any PostgresDatabase {
            try await sql.raw("""
                CREATE FUNCTION trove_protect_publication_candidate() RETURNS trigger AS $$
                BEGIN
                    IF TG_OP = 'TRUNCATE' THEN
                        RAISE EXCEPTION 'Reviewed publication evidence is immutable' USING ERRCODE = '23514';
                    END IF;
                    IF TG_OP = 'UPDATE' OR EXISTS (SELECT 1 FROM published_studies WHERE id = OLD.id) THEN
                        RAISE EXCEPTION 'Reviewed publication evidence is immutable' USING ERRCODE = '23514';
                    END IF;
                    RETURN OLD;
                END;
                $$ LANGUAGE plpgsql
                """)
                .run()
            try await sql.raw("""
                CREATE TRIGGER study_publication_candidate_no_truncate BEFORE TRUNCATE
                ON study_publication_candidates FOR EACH STATEMENT EXECUTE FUNCTION trove_protect_publication_candidate()
                """)
                .run()
            try await sql.raw("""
                CREATE TRIGGER study_publication_candidate_no_mutation BEFORE UPDATE OR DELETE
                ON study_publication_candidates FOR EACH ROW EXECUTE FUNCTION trove_protect_publication_candidate()
                """)
                .run()
        } else {
            try await sql.raw("""
                CREATE TRIGGER study_publication_candidate_no_update BEFORE UPDATE ON study_publication_candidates
                BEGIN SELECT RAISE(ABORT, 'Reviewed publication evidence is immutable'); END
                """)
                .run()
            try await sql.raw("""
                CREATE TRIGGER study_publication_candidate_no_accepted_delete BEFORE DELETE ON study_publication_candidates
                WHEN EXISTS (SELECT 1 FROM published_studies WHERE id = OLD.id)
                BEGIN SELECT RAISE(ABORT, 'Reviewed publication evidence is immutable'); END
                """)
                .run()
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        let accepted = try await sql.raw("""
            SELECT candidates.id FROM study_publication_candidates candidates
            INNER JOIN published_studies published ON published.id = candidates.id LIMIT 1
            """)
            .first()
        guard accepted == nil else { throw CreatePublishedStudies.RollbackError.retainedEvidence }
        try await database.schema(StudyPublicationCandidate.schema).delete()
        if database is any PostgresDatabase {
            try await sql.raw("DROP FUNCTION trove_protect_publication_candidate()").run()
        }
    }
}
