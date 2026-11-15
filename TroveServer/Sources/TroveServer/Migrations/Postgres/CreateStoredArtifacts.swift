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


struct CreateStoredArtifacts: AsyncMigration {
    enum RollbackError: Error { case retainedArtifacts }

    func prepare(on database: any Database) async throws {
        try await database.transaction { transaction in
            try await transaction.schema(StoredArtifact.schema)
                .id()
                .field("owner_id", .uuid, .required)
                .field("purpose", .string, .required)
                .field("digest", .string, .required)
                .field("byte_count", .int64, .required)
                .field("study_id", .uuid)
                .field("group_id", .uuid)
                .field("participant_id", .uuid)
                .field("source_binding_id", .uuid)
                .field("state", .string, .required)
                .field("expires_at", .datetime, .required)
                .field("cleanup_after", .datetime)
                .field("last_deleted_at", .datetime)
                .constraint(.custom(SQLConstraint(algorithm: SQLTableConstraintAlgorithm.check(SQLRaw("""
                    (purpose IN ('consent', 'publication') AND study_id IS NOT NULL
                        AND participant_id IS NULL AND source_binding_id IS NULL)
                    OR (purpose = 'recording' AND study_id IS NULL AND group_id IS NULL
                        AND participant_id IS NOT NULL AND source_binding_id IS NOT NULL AND owner_id = participant_id)
                    """)), name: SQLIdentifier("stored_artifact_ownership"))))
                .create()
            guard let sql = transaction as? any SQLDatabase else { throw ArtifactStore.Failure.unsupportedDatabase }
            try await sql.raw("CREATE INDEX stored_artifact_cleanup ON stored_artifacts (cleanup_after, id)").run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw ArtifactStore.Failure.unsupportedDatabase }
            if transaction is any PostgresDatabase {
                try await sql.raw("LOCK TABLE stored_artifacts IN ACCESS EXCLUSIVE MODE").run()
            }
            guard try await StoredArtifact.query(on: transaction).count() == 0 else { throw RollbackError.retainedArtifacts }
            try await transaction.schema(StoredArtifact.schema).delete()
        }
    }
}
