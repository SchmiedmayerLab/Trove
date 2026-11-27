// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Fluent
import SQLKit


struct CreateTaskCompletions: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.transaction { transaction in
            try await transaction.schema("task_sessions")
                .id()
                .field("task_id", .string, .required, .references("task_occurrences", "id", onDelete: .restrict))
                .field("evidence", .string, .required)
                .unique(on: "task_id")
                .create()
            // One accepted outcome per occurrence: a completion, a failure or an excusal, never two.
            try await transaction.schema("task_completions")
                .id()
                .field("task_id", .string, .required, .references("task_occurrences", "id", onDelete: .restrict))
                .field("session_id", .uuid, .required, .references("task_sessions", "id", onDelete: .restrict))
                .field("command_id", .uuid, .required)
                .field("response_artifact_id", .uuid, .required, .references("stored_artifacts", "id", onDelete: .restrict))
                .field("version", .int64, .required, .sql(unsafeRaw: "CHECK (version > 0)"))
                .field("receipt", .string, .required)
                .unique(on: "task_id")
                .unique(on: "session_id")
                .unique(on: "response_artifact_id")
                .create()
            try await transaction.schema("task_failures")
                .id()
                .field("task_id", .string, .required, .references("task_occurrences", "id", onDelete: .restrict))
                .field("session_id", .uuid, .required, .references("task_sessions", "id", onDelete: .restrict))
                .field("command_id", .uuid, .required)
                .field("version", .int64, .required, .sql(unsafeRaw: "CHECK (version > 0)"))
                .field("receipt", .string, .required)
                .unique(on: "task_id")
                .unique(on: "session_id")
                .create()
            try await transaction.schema("task_excusals")
                .id()
                .field("task_id", .string, .required, .references("task_occurrences", "id", onDelete: .restrict))
                .field("version", .int64, .required, .sql(unsafeRaw: "CHECK (version > 0)"))
                .field("excused_at", .datetime, .required)
                .unique(on: "task_id")
                .create()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw ServerError.unexpectedError }
            for table in ["task_sessions", "task_completions", "task_failures", "task_excusals"] {
                guard try await sql.raw("SELECT id FROM \(ident: table) LIMIT 1").all().isEmpty else {
                    throw ServerError.conflict("Task outcome history must be retained")
                }
            }
            try await transaction.schema("task_excusals").delete()
            try await transaction.schema("task_failures").delete()
            try await transaction.schema("task_completions").delete()
            try await transaction.schema("task_sessions").delete()
        }
    }
}
