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


/// No cascading foreign keys: deleting domain objects must not silently erase their history.
/// Guards prevent routine modification, not a database administrator disabling the guards.
struct CreateAuditEvents: AsyncMigration {
    enum RollbackError: Error, Equatable {
        case retainedHistory
    }

    func prepare(on database: any Database) async throws {
        // Fluent does not supply an outer migration transaction. Never leave a
        // partially created table without its append-only guards after failure.
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw AuditError.unsupportedDatabase
            }
            try await createTable(on: transaction)
            try await sql.raw("CREATE INDEX audit_events_study_time ON audit_events (study_id, group_id, occurred_at, id)").run()
            try await sql.raw("""
                CREATE INDEX audit_events_participant_source_time
                ON audit_events (participant_id, source_binding_id, occurred_at, id)
                """)
                .run()
            if transaction is any PostgresDatabase {
                try await preparePostgresGuards(on: sql)
            } else {
                try await prepareSQLiteGuards(on: sql)
            }
        }
    }

    private func createTable(on database: any Database) async throws {
        try await database.schema("audit_events")
                .id()
                .field("occurred_at", .datetime, .required)
                .field("actor_issuer", .string, .required)
                .field("actor_subject", .string, .required)
                .field("initiator_issuer", .string)
                .field("initiator_subject", .string)
                .field("executing_client_id", .string)
                .field("delegation_id", .uuid)
                .field("action", .string, .required)
                .field("scope_kind", .string, .required)
                .field("study_id", .uuid)
                .field("group_id", .uuid)
                .field("participant_id", .uuid)
                .field("source_binding_id", .uuid)
                .field("target_id", .uuid, .required)
                .field("target_version", .string)
                .field("outcome", .string, .required)
                .field("correlation_id", .uuid, .required)
                .field("application_revision", .string)
                .constraint(check("""
                    (scope_kind = 'study' AND study_id IS NOT NULL
                        AND participant_id IS NULL AND source_binding_id IS NULL)
                    OR (scope_kind = 'participant_source' AND study_id IS NULL AND group_id IS NULL
                        AND participant_id IS NOT NULL AND source_binding_id IS NOT NULL)
                    """, name: "audit_events_scope"))
                .constraint(check(actionScopeConstraint(), name: "audit_events_action_scope"))
                .create()
    }

    /// Canonical fresh schema and application share one closed action catalog.
    /// Values are compile-time enum constants, never request-provided SQL fragments.
    private func actionScopeConstraint() -> String {
        let scopes: [AuditEvent.Scope.Kind] = [.study, .participantSource]
        return scopes.map { scope in
            let actions = AuditEvent.Action.allCases.filter { $0.scopeKind == scope }
                .map { "'\($0.rawValue)'" }
                .joined(separator: ", ")
            return "(scope_kind = '\(scope.rawValue)' AND action IN (\(actions)))"
        }
        .joined(separator: " OR ")
    }

    func revert(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw AuditError.unsupportedDatabase
            }
            if transaction is any PostgresDatabase {
                // Block concurrent appends between the retention check and schema removal.
                try await sql.raw("LOCK TABLE audit_events IN ACCESS EXCLUSIVE MODE").run()
            }
            let row = try await sql.raw("SELECT COUNT(*) AS count FROM audit_events").first()
            guard let row, try row.decode(column: "count", as: Int.self) == 0 else {
                throw RollbackError.retainedHistory
            }
            try await transaction.schema("audit_events").delete()
            if transaction is any PostgresDatabase {
                try await sql.raw("DROP FUNCTION trove_reject_audit_mutation()").run()
            }
        }
    }

    private func preparePostgresGuards(on sql: any SQLDatabase) async throws {
        try await sql.raw("""
            CREATE FUNCTION trove_reject_audit_mutation() RETURNS trigger AS $$
            BEGIN
                RAISE EXCEPTION 'Audit history is append-only';
            END;
            $$ LANGUAGE plpgsql
            """)
            .run()
        try await sql.raw("""
            CREATE TRIGGER audit_events_no_mutation BEFORE UPDATE OR DELETE OR TRUNCATE
            ON audit_events FOR EACH STATEMENT EXECUTE FUNCTION trove_reject_audit_mutation()
            """)
            .run()
    }

    private func prepareSQLiteGuards(on sql: any SQLDatabase) async throws {
        try await sql.raw("""
            CREATE TRIGGER audit_events_no_update BEFORE UPDATE ON audit_events
            BEGIN SELECT RAISE(ABORT, 'Audit history is append-only'); END
            """)
            .run()
        try await sql.raw("""
            CREATE TRIGGER audit_events_no_delete BEFORE DELETE ON audit_events
            BEGIN SELECT RAISE(ABORT, 'Audit history is append-only'); END
            """)
            .run()
    }

    private func check(_ expression: String, name: String) -> DatabaseSchema.Constraint {
        .custom(SQLConstraint(algorithm: SQLTableConstraintAlgorithm.check(SQLRaw(expression)), name: SQLIdentifier(name)))
    }
}
