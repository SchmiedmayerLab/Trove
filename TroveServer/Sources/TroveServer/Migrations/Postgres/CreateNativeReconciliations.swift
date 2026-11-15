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


struct CreateNativeReconciliations: AsyncMigration {
    enum RollbackError: Error { case retainedReconciliation }

    func prepare(on database: any Database) async throws {
        try await database.schema("native_collection_reconciliations")
            .id()
            .field("source_id", .uuid, .required)
            .field("enrollment_id", .uuid, .required)
            .field("study_id", .uuid, .required)
            .field("participant_id", .uuid, .required)
            .field("scope_key", .string, .required, .sql(unsafeRaw: "CHECK (length(scope_key) = 64)"))
            .field("instruction", .string, .required, .sql(unsafeRaw: "CHECK (length(instruction) BETWEEN 1 AND 16384)"))
            .field("completed_at", .datetime)
            .unique(on: "source_id", "enrollment_id", "scope_key")
            .foreignKey(
                ["source_id", "participant_id"],
                references: "source_bindings",
                ["id", "participant_id"],
                onDelete: .restrict,
                name: "native_reconciliation_source_owner_fk"
            )
            .foreignKey(
                ["enrollment_id", "study_id", "participant_id"],
                references: "enrollments",
                ["id", "study_id", "participant_id"],
                onDelete: .restrict,
                name: "native_reconciliation_enrollment_owner_fk"
            )
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
            if transaction is any PostgresDatabase {
                try await sql.raw("LOCK TABLE native_collection_reconciliations IN ACCESS EXCLUSIVE MODE").run()
            }
            guard let row = try await sql.raw("SELECT COUNT(*) AS count FROM native_collection_reconciliations").first(),
                  try row.decode(column: "count", as: Int.self) == 0 else { throw RollbackError.retainedReconciliation }
            try await transaction.schema("native_collection_reconciliations").delete()
        }
    }
}
