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


/// Scoped identity and complete-revision membership, created inside the clinical schema transaction.
enum ClinicalRecordSchema {
    static func create(on database: any Database) async throws {
        try await database.schema("clinical_source_records")
            .id()
            .field("source_id", .uuid, .required, .references("source_bindings", "id", onDelete: .restrict))
            .field("identifier_system", .string, .required, identity("identifier_system", on: database))
            .field("identifier_value", .string, .required, identity("identifier_value", on: database))
            .unique(on: "source_id", "identifier_system", "identifier_value", name: "clinical_record_identity")
            .unique(on: "id", "source_id", name: "clinical_record_source")
            .create()
        try await createRecordEvents(on: database)
        try await database.schema("clinical_output_bindings")
            .id()
            .field("source_id", .uuid, .required)
            .field("record_id", .uuid, .required)
            .field("first_event_id", .uuid, .required)
            .field("identifier_system", .string, .required, identity("identifier_system", on: database))
            .field("identifier_value", .string, .required, identity("identifier_value", on: database))
            .unique(on: "source_id", "identifier_system", "identifier_value", name: "clinical_output_identity")
            .unique(on: "id", "record_id", "source_id", name: "clinical_output_record_source")
            .foreignKey(
                ["first_event_id", "record_id", "source_id"],
                references: "clinical_record_events",
                ["event_id", "record_id", "source_id"],
                onDelete: .restrict,
                name: "clinical_output_first_event_fk"
            )
            .create()
        try await createRetractions(on: database)
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        try await sql.raw("CREATE INDEX clinical_record_candidates ON clinical_record_events (record_id, kind)").run()
        try await sql.raw("CREATE INDEX clinical_retracted_output ON clinical_output_retractions (output_binding_id)").run()
    }

    private static func createRetractions(on database: any Database) async throws {
        try await database.schema("clinical_output_retractions")
            .field("event_id", .uuid, .required)
            .field("source_id", .uuid, .required)
            .field("record_id", .uuid, .required)
            .field("output_binding_id", .uuid, .required)
            .field("kind", .string, .required, .sql(unsafeRaw: "CHECK (kind = 'retraction')"))
            .compositeIdentifier(over: "event_id", "output_binding_id")
            .foreignKey(
                ["event_id", "record_id", "source_id", "kind"],
                references: "clinical_record_events",
                ["event_id", "record_id", "source_id", "kind"],
                onDelete: .restrict,
                name: "clinical_retraction_event_fk"
            )
            .foreignKey(
                ["output_binding_id", "record_id", "source_id"],
                references: "clinical_output_bindings",
                ["id", "record_id", "source_id"],
                onDelete: .restrict,
                name: "clinical_retraction_output_fk"
            )
            .create()
    }

    private static func createRecordEvents(on database: any Database) async throws {
        let nonDigits = "0123456789".reduce(into: "writer_version") { $0 = "replace(\($0), '\($1)', '')" }
        try await database.schema("clinical_record_events")
            .field("event_id", .uuid, .required)
            .compositeIdentifier(over: "event_id")
            .field("source_id", .uuid, .required)
            .field("record_id", .uuid, .required)
            .field("kind", .string, .required, .sql(unsafeRaw: "CHECK (kind IN ('active', 'retraction'))"))
            .field("writer_system", .string, identity("writer_system", on: database))
            .field("writer_value", .string, identity("writer_value", on: database))
            .field("writer_version", .string, .sql(unsafeRaw: """
                CHECK (length(writer_version) BETWEEN 1 AND 4096 AND length(\(nonDigits)) = 0
                    AND (writer_version = '0' OR substr(writer_version, 1, 1) BETWEEN '1' AND '9'))
                """))
            .constraint(.custom(SQLConstraint(algorithm: SQLTableConstraintAlgorithm.check(SQLRaw("""
                (writer_system IS NULL AND writer_value IS NULL AND writer_version IS NULL)
                OR (kind = 'active' AND writer_system IS NOT NULL AND writer_value IS NOT NULL AND writer_version IS NOT NULL)
                """)))))
            .unique(on: "event_id", "record_id", "source_id", name: "clinical_record_event_source")
            .unique(on: "event_id", "record_id", "source_id", "kind", name: "clinical_record_event_kind")
            .foreignKey(
                ["event_id", "source_id"],
                references: "clinical_events",
                ["id", "source_id"],
                onDelete: .restrict,
                name: "clinical_record_event_fk"
            )
            .foreignKey(
                ["record_id", "source_id"],
                references: "clinical_source_records",
                ["id", "source_id"],
                onDelete: .restrict,
                name: "clinical_record_source_fk"
            )
            .create()
    }

    /// Byte bounds keep complete identifier indexes bounded even for multibyte text.
    static func identity(_ column: String, on database: any Database) -> DatabaseSchema.FieldConstraint {
        let postgres = database is any PostgresDatabase
        let length = postgres ? "octet_length(\(column))" : "length(CAST(\(column) AS BLOB))"
        let collation = postgres ? "\"C\"" : "BINARY"
        return .sql(unsafeRaw: "COLLATE \(collation) CHECK (\(length) BETWEEN 1 AND 512)")
    }
}
