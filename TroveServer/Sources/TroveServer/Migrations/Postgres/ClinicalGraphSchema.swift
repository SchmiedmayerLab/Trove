//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import FluentSQL
import SQLKit


enum ClinicalGraphSchema {
    static func create(on database: any Database) async throws {
        try await createContexts(on: database)
        try await createDerivations(on: database)
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        try await sql.raw("""
            CREATE INDEX clinical_context_identity ON clinical_questionnaire_contexts (source_id, identifier_system, identifier_value)
            """)
            .run()
        try await sql.raw("CREATE INDEX clinical_direct_context ON clinical_point_derivations (target_node_id, node_id)").run()
    }

    private static func createContexts(on database: any Database) async throws {
        try await database.schema("clinical_questionnaire_contexts")
            .field("node_id", .uuid, .required)
            .compositeIdentifier(over: "node_id")
            .field("event_id", .uuid, .required)
            .field("source_id", .uuid, .required)
            .field("resource_type", .string, .required, .sql(unsafeRaw: """
                DEFAULT 'QuestionnaireResponse' CHECK (resource_type = 'QuestionnaireResponse')
                """))
            .field("identifier_system", .string, .required, ClinicalRecordSchema.identity("identifier_system", on: database))
            .field("identifier_value", .string, .required, ClinicalRecordSchema.identity("identifier_value", on: database))
            .unique(on: "node_id", "event_id", "source_id", name: "clinical_context_event_source")
            .foreignKey(
                ["node_id", "event_id", "source_id", "resource_type"],
                references: "clinical_event_nodes",
                ["id", "event_id", "source_id", "resource_type"],
                onDelete: .restrict,
                name: "clinical_context_node_fk"
            )
            .create()
    }

    private static func createDerivations(on database: any Database) async throws {
        try await database.schema("clinical_point_derivations")
            .field("node_id", .uuid, .required)
            .field("ordinal", .int, .required, .sql(unsafeRaw: "CHECK (ordinal BETWEEN 0 AND 511)"))
            .compositeIdentifier(over: "node_id", "ordinal")
            .field("event_id", .uuid, .required)
            .field("source_id", .uuid, .required)
            .field("target_node_id", .uuid)
            .field("identifier_system", .string, ClinicalRecordSchema.identity("identifier_system", on: database))
            .field("identifier_value", .string, ClinicalRecordSchema.identity("identifier_value", on: database))
            .constraint(.custom(SQLConstraint(algorithm: SQLTableConstraintAlgorithm.check(SQLRaw("""
                (target_node_id IS NOT NULL AND identifier_system IS NULL AND identifier_value IS NULL)
                OR (target_node_id IS NULL AND identifier_system IS NOT NULL AND identifier_value IS NOT NULL)
                """)))))
            .foreignKey(
                ["node_id", "source_id"],
                references: "clinical_point_facts",
                ["node_id", "source_id"],
                onDelete: .restrict,
                name: "clinical_derivation_point_fk"
            )
            .foreignKey(
                ["node_id", "event_id", "source_id"],
                references: "clinical_event_nodes",
                ["id", "event_id", "source_id"],
                onDelete: .restrict,
                name: "clinical_derivation_node_fk"
            )
            .foreignKey(
                ["target_node_id", "event_id", "source_id"],
                references: "clinical_questionnaire_contexts",
                ["node_id", "event_id", "source_id"],
                onDelete: .restrict,
                name: "clinical_derivation_context_fk"
            )
            .create()
    }
}
