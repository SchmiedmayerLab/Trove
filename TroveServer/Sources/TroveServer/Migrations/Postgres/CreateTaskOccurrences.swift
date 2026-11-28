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


/// Adds the published task plan, the enrollment closure base, the occurrences and their synchronization cursors.
///
/// The task plan has no PostgreSQL default: a database that already holds publications cannot be upgraded by
/// inventing their schedules. SQLite, which serves only fresh test databases, requires a default for the column.
struct CreateTaskOccurrences: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
            let plan = transaction is any PostgresDatabase ? "jsonb NOT NULL" : #"json NOT NULL DEFAULT '{"schedules":[]}'"#
            try await sql.raw("ALTER TABLE published_studies ADD COLUMN task_plan \(unsafeRaw: plan)").run()
            try await sql.raw("ALTER TABLE enrollments ADD COLUMN task_closure_base bigint").run()
            try await transaction.schema("task_occurrences")
                .field("id", .string, .identifier(auto: false))
                .field("enrollment_id", .uuid, .required, .references("enrollments", "id", onDelete: .cascade))
                .field("publication_id", .uuid, .required, .references("published_studies", "id", onDelete: .restrict))
                .field("due_at", .datetime, .required)
                // The end of the performance window; NULL for an occurrence without a deadline.
                .field("cutoff_at", .datetime)
                .field("assigned_version", .int64, .required, .sql(unsafeRaw: "CHECK (assigned_version > 0)"))
                .field("invalidated_version", .int64, .sql(unsafeRaw: "CHECK (invalidated_version > assigned_version)"))
                // When the server recorded the assignment, and when it recorded its removal. A removal by an individual
                // version always records its time; an enrollment closure records the time without a version.
                .field("assigned_at", .datetime, .required)
                .field("invalidated_at", .datetime, .sql(unsafeRaw: "CHECK (invalidated_at IS NOT NULL OR invalidated_version IS NULL)"))
                .field("projection", .string, .required)
                .unique(on: "enrollment_id", "assigned_version")
                .unique(on: "enrollment_id", "invalidated_version")
                .create()
            try await Self.createCursors(on: transaction)
            try await sql.raw(
                "CREATE INDEX task_open_assignments ON task_occurrences(enrollment_id, assigned_version) WHERE invalidated_version IS NULL"
            )
                .run()
            try await sql.raw("CREATE INDEX task_assignment_window ON task_occurrences(enrollment_id, due_at, id)").run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase,
                try await sql.raw("SELECT id FROM task_occurrences LIMIT 1").all().isEmpty
            else {
                throw ServerError.conflict("Task history must be retained")
            }
            try await transaction.schema("task_sync_cursors").delete()
            try await transaction.schema("task_occurrences").delete()
            try await sql.raw("ALTER TABLE enrollments DROP COLUMN task_closure_base").run()
            try await sql.raw("ALTER TABLE published_studies DROP COLUMN task_plan").run()
        }
    }
}


extension CreateTaskOccurrences {
    private static func createCursors(on transaction: any Database) async throws {
        guard let sql = transaction as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        try await transaction.schema("task_sync_cursors")
            .id()
            .field("enrollment_id", .uuid, .required, .references("enrollments", "id", onDelete: .cascade))
            .field("participant_id", .uuid, .required)
            .field("projection_version", .int, .required)
            .field("enrollment_version", .int64, .required)
            .field("active", .bool, .required)
            .field("after_version", .int64, .required)
            .field("upper_version", .int64)
            .field("snapshot", .bool, .required)
            .field("expires_at", .datetime, .required)
            .create()
        try await sql.raw("CREATE INDEX task_cursor_expiry ON task_sync_cursors(enrollment_id, expires_at)").run()
    }
}
