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


/// Approval records bind one exact Questionnaire digest and one administration language.
/// A record is written once; only its revocation can be added afterwards.
struct CreateQuestionnaireLanguageApprovals: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
            let digest = transaction is any PostgresDatabase
                ? "sha256 ~ '^[0-9a-f]{64}$'"
                : "length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'"
            try await transaction.schema(QuestionnaireLanguageApproval.schema)
                .id()
                .field("study_id", .uuid, .required, .references("studies", "id", onDelete: .cascade))
                .field("component_id", .uuid, .required, .references("components", "id", onDelete: .cascade))
                .field("sha256", .string, .required)
                .field("language", .string, .required)
                .field("approved_by_issuer", .string, .required)
                .field("approved_by_subject", .string, .required)
                .field("approved_at", .datetime, .required)
                .field("revoked_at", .datetime)
                .field("revoked_by_issuer", .string)
                .field("revoked_by_subject", .string)
                .constraint(.custom(SQLConstraint(algorithm: SQLTableConstraintAlgorithm.check(SQLRaw("""
                    \(digest) AND length(language) BETWEEN 1 AND 35
                    AND length(approved_by_issuer) BETWEEN 1 AND 2048 AND length(approved_by_subject) BETWEEN 1 AND 255
                    AND ((revoked_at IS NULL AND revoked_by_issuer IS NULL AND revoked_by_subject IS NULL)
                        OR (revoked_at IS NOT NULL AND revoked_by_issuer IS NOT NULL AND revoked_by_subject IS NOT NULL
                            AND revoked_at >= approved_at AND length(revoked_by_issuer) BETWEEN 1 AND 2048
                            AND length(revoked_by_subject) BETWEEN 1 AND 255))
                    """)), name: SQLIdentifier("questionnaire_language_approvals_valid"))))
                .create()
            try await sql.raw("""
                CREATE UNIQUE INDEX questionnaire_language_approval_in_force
                ON questionnaire_language_approvals (component_id, sha256, language) WHERE revoked_at IS NULL
                """)
                .run()
            try await protect(on: transaction, sql: sql)
        }
    }

    /// Only an approval in force can be revoked, and nothing else about it can change.
    private func protect(on database: any Database, sql: any SQLDatabase) async throws {
        let unchanged = """
            NEW.id = OLD.id AND NEW.study_id = OLD.study_id AND NEW.component_id = OLD.component_id
            AND NEW.sha256 = OLD.sha256 AND NEW.language = OLD.language
            AND NEW.approved_by_issuer = OLD.approved_by_issuer AND NEW.approved_by_subject = OLD.approved_by_subject
            AND NEW.approved_at = OLD.approved_at AND OLD.revoked_at IS NULL
            """
        if database is any PostgresDatabase {
            try await sql.raw("""
                CREATE FUNCTION trove_protect_language_approval() RETURNS trigger AS $$
                BEGIN
                    IF NOT (\(unsafeRaw: unchanged)) THEN
                        RAISE EXCEPTION 'Language approvals change only by revocation' USING ERRCODE = '23514';
                    END IF;
                    RETURN NEW;
                END;
                $$ LANGUAGE plpgsql
                """)
                .run()
            try await sql.raw("""
                CREATE TRIGGER questionnaire_language_approval_revocation_only BEFORE UPDATE
                ON questionnaire_language_approvals FOR EACH ROW EXECUTE FUNCTION trove_protect_language_approval()
                """)
                .run()
        } else {
            try await sql.raw("""
                CREATE TRIGGER questionnaire_language_approval_revocation_only BEFORE UPDATE ON questionnaire_language_approvals
                WHEN NOT (\(unsafeRaw: unchanged))
                BEGIN SELECT RAISE(ABORT, 'Language approvals change only by revocation'); END
                """)
                .run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(QuestionnaireLanguageApproval.schema).delete()
        if database is any PostgresDatabase, let sql = database as? any SQLDatabase {
            try await sql.raw("DROP FUNCTION trove_protect_language_approval()").run()
        }
    }
}
