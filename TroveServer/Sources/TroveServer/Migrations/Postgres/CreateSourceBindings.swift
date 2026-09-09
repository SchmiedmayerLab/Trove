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
    func prepare(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
            try await transaction.schema("source_bindings")
                .id()
                .field("participant_id", .uuid, .required, .references("participants", "id", onDelete: .restrict))
                .field("registration_id", .uuid, .required)
                .field("kind", .string, .required)
                .field("event_identifier_system", .string, .required)
                .field("participant_identifier_system", .string, .required)
                .field("participant_identifier_value", .string, .required)
                .field("created_at", .datetime, .required)
                .field("revoked_at", .datetime)
                .unique(on: "participant_id", "registration_id")
                .unique(on: "event_identifier_system")
                .unique(on: "id", "participant_id", name: "source_participant_identity")
                .constraint(.custom(SQLConstraint(algorithm: SQLTableConstraintAlgorithm.check(SQLRaw("""
                    kind = 'participant-app' AND length(event_identifier_system) > 0
                    AND length(participant_identifier_system) > 0 AND length(participant_identifier_value) > 0
                    AND (revoked_at IS NULL OR revoked_at >= created_at)
                    """)))))
                .create()
            try await prepareIdentityGuard(on: sql, postgres: transaction is any PostgresDatabase)
        }
    }

    func revert(on database: any Database) async throws {
        try await database.transaction { transaction in
            try await transaction.schema("source_bindings").delete()
            if transaction is any PostgresDatabase, let sql = transaction as? any SQLDatabase {
                try await sql.raw("DROP FUNCTION trove_protect_source_binding()").run()
            }
        }
    }

    private func prepareIdentityGuard(on sql: any SQLDatabase, postgres: Bool) async throws {
        let columns = [
            "id", "participant_id", "registration_id", "kind", "event_identifier_system",
            "participant_identifier_system", "participant_identifier_value", "created_at"
        ]
        let differs = postgres ? "IS DISTINCT FROM" : "IS NOT"
        let changed = columns.map { "NEW.\($0) \(differs) OLD.\($0)" }.joined(separator: " OR ")
        let condition = "(\(changed)) OR (OLD.revoked_at IS NOT NULL AND NEW.revoked_at \(differs) OLD.revoked_at)"
        if postgres {
            try await sql.raw(SQLQueryString("""
                CREATE FUNCTION trove_protect_source_binding() RETURNS trigger AS $$
                BEGIN
                    IF TG_OP <> 'UPDATE' THEN
                        RAISE EXCEPTION 'Source binding history is retained' USING ERRCODE = '23514';
                    END IF;
                    IF \(unsafeRaw: condition) THEN
                        RAISE EXCEPTION 'Source binding identity and revocation are immutable' USING ERRCODE = '23514';
                    END IF;
                    RETURN NEW;
                END;
                $$ LANGUAGE plpgsql
                """))
                .run()
            try await sql.raw("""
                CREATE TRIGGER source_bindings_identity BEFORE UPDATE ON source_bindings
                FOR EACH ROW EXECUTE FUNCTION trove_protect_source_binding()
                """)
                .run()
            try await sql.raw("""
                CREATE TRIGGER source_bindings_no_removal BEFORE DELETE OR TRUNCATE ON source_bindings
                FOR EACH STATEMENT EXECUTE FUNCTION trove_protect_source_binding()
                """)
                .run()
        } else {
            try await sql.raw(SQLQueryString("""
                CREATE TRIGGER source_bindings_identity BEFORE UPDATE ON source_bindings
                WHEN \(unsafeRaw: condition)
                BEGIN SELECT RAISE(ABORT, 'Source binding identity and revocation are immutable'); END
                """))
                .run()
            try await sql.raw("""
                CREATE TRIGGER source_bindings_no_removal BEFORE DELETE ON source_bindings
                BEGIN SELECT RAISE(ABORT, 'Source binding history is retained'); END
                """)
                .run()
        }
    }
}
