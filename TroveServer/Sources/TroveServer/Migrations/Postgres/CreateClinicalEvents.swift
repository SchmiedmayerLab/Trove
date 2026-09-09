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


/// One payload per event, entry addresses, lossless point facts, and independent study decisions.
struct CreateClinicalEvents: AsyncMigration {
    enum RollbackError: Error, Equatable { case retainedEvents }

    private static let tables = [
        "clinical_events", "clinical_source_records", "clinical_record_events", "clinical_output_bindings",
        "clinical_output_retractions",
        "clinical_event_nodes", "clinical_point_facts", "clinical_questionnaire_contexts", "clinical_point_derivations",
        "study_data_grants", "clinical_attribution_commands"
    ]

    func prepare(on database: any Database) async throws {
        try await database.transaction { transaction in
            try await createEvents(on: transaction)
            try await ClinicalRecordSchema.create(on: transaction)
            try await createNodes(on: transaction)
            try await createFacts(on: transaction)
            try await ClinicalGraphSchema.create(on: transaction)
            try await createGrants(on: transaction)
            try await transaction.schema("clinical_attribution_commands")
                .id()
                .field("source_id", .uuid, .required)
                .field("command_id", .uuid, .required)
                .field("event_id", .uuid, .required)
                .field("target_intent", .string, .required, boundedText("target_intent", maximum: ClinicalEventIntent.maximumBytes))
                .field("accepted_at", .datetime, .required)
                .field("authorized_output_count", .int, .required, .sql(unsafeRaw: "CHECK (authorized_output_count BETWEEN 1 AND 8192)"))
                .unique(on: "source_id", "command_id", name: "clinical_attribution_command_identity")
                .foreignKey(
                    ["event_id", "source_id"],
                    references: "clinical_events",
                    ["id", "source_id"],
                    onDelete: .restrict,
                    name: "clinical_attribution_event_fk"
                )
                .create()
            guard let sql = transaction as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
            try await sql.raw("CREATE INDEX clinical_point_time ON clinical_point_facts (profile, effective_at, node_id)").run()
            try await sql.raw("CREATE INDEX study_grant_enrollment ON study_data_grants (enrollment_id, node_id)").run()
            try await sql.raw("CREATE INDEX study_grant_study ON study_data_grants (study_id, node_id)").run()
            try await protectRecords(on: sql, postgres: transaction is any PostgresDatabase)
        }
    }

    private func createEvents(on database: any Database) async throws {
        let byteLength = database is any PostgresDatabase ? "octet_length(raw_bytes)" : "length(raw_bytes)"
        let nonHex = "0123456789abcdef".reduce(into: "raw_sha256") { $0 = "replace(\($0), '\($1)', '')" }
        try await database.schema("clinical_events")
            .id()
            .field("source_id", .uuid, .required, .references("source_bindings", "id", onDelete: .restrict))
            .field("identifier_system", .string, .required, ClinicalRecordSchema.identity("identifier_system", on: database))
            .field("identifier_value", .string, .required, ClinicalRecordSchema.identity("identifier_value", on: database))
            .field("raw_bytes", .data, .required, .sql(unsafeRaw: "CHECK (\(byteLength) BETWEEN 1 AND 4194304)"))
            .field("raw_sha256", .string, .required, .sql(unsafeRaw: "CHECK (length(raw_sha256) = 64 AND length(\(nonHex)) = 0)"))
            .field("validator_identity", .string, .required, boundedText("validator_identity"))
            .field("target_intent", .string, .required, boundedText("target_intent", maximum: ClinicalEventIntent.maximumBytes))
            .field("received_at", .datetime, .required)
            .field("node_count", .int, .required, .sql(unsafeRaw: "CHECK (node_count BETWEEN 1 AND 512)"))
            .unique(on: "identifier_system", "identifier_value", name: "clinical_event_identity")
            .unique(on: "id", "source_id", name: "clinical_event_source")
            .create()
    }

    private func createNodes(on database: any Database) async throws {
        try await database.schema("clinical_event_nodes")
            .id()
            .field("event_id", .uuid, .required)
            .field("source_id", .uuid, .required)
            .field("full_url", .string, .required, boundedText("full_url"))
            .field("ordinal", .int, .required, .sql(unsafeRaw: "CHECK (ordinal BETWEEN 0 AND 511)"))
            .field("resource_type", .string, .required, boundedText("resource_type", maximum: 64))
            .unique(on: "event_id", "full_url", name: "clinical_node_address")
            .unique(on: "event_id", "ordinal", name: "clinical_node_ordinal")
            .unique(on: "id", "source_id", name: "clinical_node_source")
            .unique(on: "id", "event_id", "source_id", name: "clinical_node_event_source")
            .unique(on: "id", "event_id", "source_id", "resource_type", name: "clinical_node_resource_type")
            .foreignKey(
                ["event_id", "source_id"],
                references: "clinical_events",
                ["id", "source_id"],
                onDelete: .restrict,
                name: "clinical_node_event_fk"
            )
            .create()
    }

    private func createFacts(on database: any Database) async throws {
        try await database.schema("clinical_point_facts")
            .field("node_id", .uuid, .required)
            .compositeIdentifier(over: "node_id")
            .field("source_id", .uuid, .required)
            .field("event_id", .uuid, .required)
            .field("record_id", .uuid, .required)
            .field("output_binding_id", .uuid, .required)
            .field("profile", .string, .required, boundedText("profile"))
            .field("effective_at", .datetime, .required)
            .field("quantity_value", .string, .required, boundedText("quantity_value", maximum: 4096))
            .field("quantity_system", .string, .required, boundedText("quantity_system"))
            .field("quantity_code", .string, .required, boundedText("quantity_code"))
            .field("code_system", .string, .required, boundedText("code_system"))
            .field("code", .string, .required, boundedText("code"))
            .unique(on: "event_id", "output_binding_id", name: "clinical_point_output")
            .unique(on: "node_id", "source_id", name: "clinical_point_source")
            .foreignKey(
                ["node_id", "event_id", "source_id"],
                references: "clinical_event_nodes",
                ["id", "event_id", "source_id"],
                onDelete: .restrict,
                name: "clinical_point_node_fk"
            )
            .foreignKey(
                ["event_id", "record_id", "source_id"],
                references: "clinical_record_events",
                ["event_id", "record_id", "source_id"],
                onDelete: .restrict,
                name: "clinical_point_record_fk"
            )
            .foreignKey(
                ["output_binding_id", "record_id", "source_id"],
                references: "clinical_output_bindings",
                ["id", "record_id", "source_id"],
                onDelete: .restrict,
                name: "clinical_point_output_fk"
            )
            .create()
    }

    private func createGrants(on database: any Database) async throws {
        try await database.schema("study_data_grants")
            .id()
            .field("node_id", .uuid, .required)
            .field("source_id", .uuid, .required)
            .field("participant_id", .uuid, .required)
            .field("study_id", .uuid, .required)
            .field("enrollment_id", .uuid, .required)
            .field("consent_id", .uuid, .required)
            .field("publication_id", .uuid, .required)
            .field("revision", .int, .required, .sql(unsafeRaw: "CHECK (revision > 0)"))
            .field("accepted_at", .datetime, .required)
            .unique(on: "node_id", "enrollment_id", "consent_id", name: "study_grant_consent")
            .foreignKey(
                ["publication_id", "study_id", "revision"],
                references: "published_studies",
                ["id", "study_id", "revision"],
                onDelete: .restrict,
                name: "study_grant_publication_fk"
            )
            .foreignKey(
                ["consent_id", "enrollment_id", "revision"],
                references: "enrollment_consents",
                ["id", "enrollment_id", "revision"],
                onDelete: .restrict,
                name: "study_grant_consent_fk"
            )
            .foreignKey(
                ["node_id", "source_id"],
                references: "clinical_point_facts",
                ["node_id", "source_id"],
                onDelete: .restrict,
                name: "study_grant_point_fk"
            )
            .foreignKey(
                ["source_id", "participant_id"],
                references: "source_bindings",
                ["id", "participant_id"],
                onDelete: .restrict,
                name: "study_grant_source_fk"
            )
            .foreignKey(
                ["enrollment_id", "study_id", "participant_id"],
                references: "enrollments",
                ["id", "study_id", "participant_id"],
                onDelete: .restrict,
                name: "study_grant_enrollment_fk"
            )
            .create()
    }

    /// Receiver capability bounds, not a replacement for complete FHIR validation.
    private func boundedText(_ column: String, maximum: Int = 512) -> DatabaseSchema.FieldConstraint {
        .sql(unsafeRaw: "CHECK (length(\(column)) BETWEEN 1 AND \(maximum))")
    }

    func revert(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
            if transaction is any PostgresDatabase {
                try await sql.raw("""
                    LOCK TABLE clinical_events, clinical_source_records, clinical_record_events, clinical_output_bindings,
                        clinical_output_retractions,
                        clinical_event_nodes, clinical_point_facts, clinical_questionnaire_contexts, clinical_point_derivations,
                        study_data_grants, clinical_attribution_commands IN ACCESS EXCLUSIVE MODE
                    """)
                    .run()
            }
            let row = try await sql.raw("SELECT COUNT(*) AS count FROM clinical_events").first()
            guard let row, try row.decode(column: "count", as: Int.self) == 0 else { throw RollbackError.retainedEvents }
            for table in Self.tables.reversed() {
                try await transaction.schema(table).delete()
            }
            if transaction is any PostgresDatabase {
                try await sql.raw("DROP FUNCTION trove_reject_clinical_mutation()").run()
            }
        }
    }

    private func protectRecords(on sql: any SQLDatabase, postgres: Bool) async throws {
        if postgres {
            try await sql.raw("""
                CREATE FUNCTION trove_reject_clinical_mutation() RETURNS trigger AS $$
                BEGIN RAISE EXCEPTION 'Clinical event and grant history is append-only' USING ERRCODE = '23514'; END;
                $$ LANGUAGE plpgsql
                """)
                .run()
        }
        for table in Self.tables {
            if postgres {
                try await sql.raw("""
                    CREATE TRIGGER \(ident: table + "_no_mutation") BEFORE UPDATE OR DELETE OR TRUNCATE
                    ON \(ident: table) FOR EACH STATEMENT EXECUTE FUNCTION trove_reject_clinical_mutation()
                    """)
                    .run()
            } else {
                for operation in ["UPDATE", "DELETE"] {
                    try await sql.raw("""
                        CREATE TRIGGER \(ident: table + "_no_" + operation.lowercased()) BEFORE \(unsafeRaw: operation) ON \(ident: table)
                        BEGIN SELECT RAISE(ABORT, 'Clinical event and grant history is append-only'); END
                        """)
                        .run()
                }
            }
        }
    }
}
