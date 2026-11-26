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


/// Adds the draft readiness facts, the questionnaire administration languages and the publication evidence that
/// records the definition schema, the IG contract and the instruments separately from the revision.
///
/// Draft columns default to empty facts and no administration language, which validation reports as blockers.
/// Publication evidence has no PostgreSQL default: a database that already holds publications cannot be upgraded
/// by inventing their evidence. SQLite, which serves only fresh test databases, requires a default for the column.
struct AddPublicationReadiness: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
            let postgres = transaction is any PostgresDatabase
            let json = postgres ? "jsonb" : "json"
            try await sql.raw("""
                ALTER TABLE studies ADD COLUMN readiness_facts \(unsafeRaw: json) NOT NULL DEFAULT '{"content":{},"contacts":[]}'
                """)
                .run()
            try await sql.raw("""
                ALTER TABLE components ADD COLUMN administration \(unsafeRaw: json) NOT NULL DEFAULT '{"languages":[]}'
                """)
                .run()
            let text = postgres ? "text NOT NULL" : "text NOT NULL DEFAULT ''"
            let instruments = postgres ? "jsonb NOT NULL" : #"json NOT NULL DEFAULT '{"instruments":[]}'"#
            let facts = postgres ? "jsonb NOT NULL" : #"json NOT NULL DEFAULT '{"content":{},"contacts":[]}'"#
            for (column, type) in [
                ("definition_schema_version", text), ("contract_version", text), ("contract_revision", text),
                ("validator_identity", text), ("execution_capability", text), ("instruments", instruments), ("readiness_facts", facts)
            ] {
                try await sql.raw("ALTER TABLE published_studies ADD COLUMN \(ident: column) \(unsafeRaw: type)").run()
            }
        }
    }

    func revert(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
            let row = try await sql.raw("SELECT COUNT(*) AS count FROM published_studies").first()
            guard let row, try row.decode(column: "count", as: Int.self) == 0 else {
                throw CreatePublishedStudies.RollbackError.retainedEvidence
            }
            for column in [
                "definition_schema_version", "contract_version", "contract_revision", "validator_identity", "execution_capability",
                "instruments", "readiness_facts"
            ] {
                try await sql.raw("ALTER TABLE published_studies DROP COLUMN \(ident: column)").run()
            }
            try await sql.raw("ALTER TABLE components DROP COLUMN administration").run()
            try await sql.raw("ALTER TABLE studies DROP COLUMN readiness_facts").run()
        }
    }
}
