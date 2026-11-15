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
import TroveAPITypes


struct CreateProviderConnections: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.transaction { transaction in
            try await ProviderGlobalScopeSchema.prepare(on: transaction)
            try await self.connections(on: transaction)
            try await self.linkIntents(on: transaction)
            try await self.checkpoints(on: transaction)
            try await self.queryCoverage(on: transaction)
            try await self.retainedSelectionIndexes(on: transaction)
            try await self.conversionInstants(on: transaction)
            try await ProviderWorkerSchema.prepare(on: transaction)
        }
    }

    private func connections(on database: any Database) async throws {
        try await database.schema("provider_connections")
            .id()
            .field("participant_id", .uuid, .required, .references("participants", "id", onDelete: .restrict))
            .field("registration_id", .uuid, .required, .references("provider_registrations", "id", onDelete: .restrict))
            .field("source_id", .uuid, .required, .references("source_bindings", "id", onDelete: .restrict))
            .field("account_pseudonym", .uuid, .required)
            .field("generation", .int64, .required, .sql(unsafeRaw: "CHECK (generation > 0)"))
            .field("credential_version", .int64, .required, .sql(unsafeRaw: "CHECK (credential_version > 0)"))
            .field(
                "credential_envelope",
                .string,
                .sql(unsafeRaw: "CHECK (credential_envelope IS NULL OR length(credential_envelope) BETWEEN 1 AND 90000)")
            )
            .field("account_envelope", .string, .required, .sql(unsafeRaw: "CHECK (length(account_envelope) BETWEEN 1 AND 2048)"))
            .field("dormant_until", .datetime, .required)
            .field("status", .string, .required, .sql(unsafeRaw: "CHECK (status IN ('active', 'disconnected', 'reauthorization-required'))"))
            .field("refresh_state", .string, .required, .sql(unsafeRaw: "CHECK (refresh_state IN ('ready', 'dispatched', 'uncertain'))"))
            .field("refresh_id", .uuid)
            .field("created_at", .datetime, .required)
            .field("last_attempt", .datetime)
            .field("last_successful_fetch", .datetime)
            .field("next_attempt", .datetime, .required)
            .create()
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        try await sql.raw("""
            CREATE UNIQUE INDEX provider_connections_one_current
            ON provider_connections (participant_id, registration_id) WHERE status <> 'disconnected'
            """)
            .run()
    }

    private func linkIntents(on database: any Database) async throws {
        try await database.schema("provider_link_intents")
            .id()
            .field("participant_id", .uuid, .required, .references("participants", "id", onDelete: .restrict))
            .field("registration_id", .uuid, .required, .references("provider_registrations", "id", onDelete: .restrict))
            .field("registration_generation", .int64, .required, .sql(unsafeRaw: "CHECK (registration_generation > 0)"))
            .field("redirect_id", .string, .required)
            .field("state_digest", .string, .required, .sql(unsafeRaw: "CHECK (length(state_digest) = 64)"))
            .field("verifier_envelope", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("status", .string, .required, .sql(unsafeRaw: "CHECK (status IN ('pending', 'dispatched', 'complete', 'uncertain'))"))
            .field("connection_id", .uuid, .references("provider_connections", "id", onDelete: .restrict))
            .unique(on: "state_digest")
            .create()
    }

    private func checkpoints(on database: any Database) async throws {
        let byteLength = database is any PostgresDatabase ? "octet_length(record_bytes)" : "length(record_bytes)"
        try await database.schema("provider_checkpoints")
            .id()
            .field("connection_id", .uuid, .required, .references("provider_connections", "id", onDelete: .restrict))
            .field("source_token", .string, .required, .sql(unsafeRaw: "CHECK (length(source_token) BETWEEN 1 AND 255)"))
            .field("purpose", .string, .required, .sql(unsafeRaw: "CHECK (purpose IN ('ordinary', 'reconciliation'))"))
            .field("query_as_of", .datetime, .required)
            .field("failure_count", .int, .required, .sql(unsafeRaw: "CHECK (failure_count BETWEEN 0 AND 16)"))
            .field("window_start", .datetime, .required)
            .field("window_end", .datetime, .required)
            .field("query_coverage", .string, .required, .sql(unsafeRaw: "CHECK (length(query_coverage) BETWEEN 1 AND 1048576)"))
            .field("coverage_digest", .string, .required, .sql(unsafeRaw: "CHECK (length(coverage_digest) = 64)"))
            .field("cursor", .string, .sql(unsafeRaw: "CHECK (cursor IS NULL OR length(cursor) BETWEEN 1 AND 4096)"))
            .field("accepted_through", .datetime)
            .field("generation", .int64, .required, .sql(unsafeRaw: "CHECK (generation > 0)"))
            .field("lease_id", .uuid)
            .field("lease_until", .datetime)
            .field("status", .string, .required, .sql(unsafeRaw: "CHECK (status IN ('ready', 'fetching', 'staged', 'blocked', 'complete'))"))
            .field("next_cursor", .string, .sql(unsafeRaw: "CHECK (next_cursor IS NULL OR length(next_cursor) BETWEEN 1 AND 4096)"))
            .field("page_complete", .bool, .required)
            .field("excluded_rows", .int, .required, .sql(unsafeRaw: "CHECK (excluded_rows BETWEEN 0 AND 100000)"))
            .field("acquired_at", .datetime)
            .field("acquisition_facts", .string)
            .field("page_sequence", .int64, .required, .sql(unsafeRaw: "CHECK (page_sequence > 0)"))
            .unique(on: "connection_id", "source_token", "purpose", "window_start", "window_end", "coverage_digest")
            .create()
        try await database.schema("provider_staged_records")
            .id()
            .field("checkpoint_id", .uuid, .required, .references("provider_checkpoints", "id", onDelete: .restrict))
            .field("page_sequence", .int64, .required, .sql(unsafeRaw: "CHECK (page_sequence > 0)"))
            .field("ordinal", .int, .required, .sql(unsafeRaw: "CHECK (ordinal BETWEEN 0 AND 1023)"))
            .field("record_bytes", .data, .required, .sql(unsafeRaw: "CHECK (\(byteLength) BETWEEN 1 AND \(EventSubmissionLimits.maximumEventBytes))"))
            .field("record_digest", .string, .required, .sql(unsafeRaw: "CHECK (length(record_digest) = 64)"))
            .field("target_intent", .string, .required, .sql(unsafeRaw: "CHECK (length(target_intent) BETWEEN 1 AND 1048576)"))
            .field("event_id", .uuid, .references("clinical_events", "id", onDelete: .restrict))
            .unique(on: "checkpoint_id", "page_sequence", "ordinal")
            .create()
    }

    private func queryCoverage(on database: any Database) async throws {
        try await database.schema("provider_query_coverage")
            .id()
            .field("checkpoint_id", .uuid, .required, .references("provider_checkpoints", "id", onDelete: .restrict))
            .field("profile", .string, .required, .sql(unsafeRaw: "CHECK (length(profile) BETWEEN 1 AND 2048)"))
            .field("window_start", .datetime, .required)
            .field("window_end", .datetime, .required)
            .unique(on: "checkpoint_id", "profile", "window_start", "window_end")
            .create()
        try await ProviderSQL.sql(database)
            .raw("""
            CREATE INDEX provider_coverage_window ON provider_query_coverage (profile, window_start, window_end, checkpoint_id)
            """)
            .run()
        try await ProviderGlobalScopeSchema.protect(table: "provider_query_coverage", on: database)
    }

    private func retainedSelectionIndexes(on database: any Database) async throws {
        let sql = try ProviderSQL.sql(database)
        try await sql.raw("""
            CREATE INDEX provider_staged_custody_event ON provider_staged_records (event_id) WHERE event_id IS NOT NULL
            """)
            .run()
        try await sql.raw("""
            CREATE INDEX provider_retained_outputs ON clinical_point_facts (source_id, source_type_identifier, profile, event_id)
            """)
            .run()
    }

    private func conversionInstants(on database: any Database) async throws {
        let byteLength = database is any PostgresDatabase ? "octet_length(source_evidence)" : "length(source_evidence)"
        try await database.schema("provider_conversion_instants")
            .id()
            .field("source_id", .uuid, .required, .references("source_bindings", "id", onDelete: .restrict))
            .field("source_token", .string, .required)
            .field("native_identifier_digest", .string, .required, .sql(unsafeRaw: "CHECK (length(native_identifier_digest) = 64)"))
            .field("content_fingerprint", .string, .required, .sql(unsafeRaw: "CHECK (length(content_fingerprint) = 64)"))
            .field("converter_fingerprint", .string, .required, .sql(unsafeRaw: "CHECK (length(converter_fingerprint) = 64)"))
            .field("source_evidence", .data, .required, .sql(unsafeRaw: "CHECK (\(byteLength) BETWEEN 1 AND \(EventSubmissionLimits.maximumEventBytes))"))
            .field("converted_at", .datetime, .required)
            .unique(on: "source_id", "source_token", "native_identifier_digest", "content_fingerprint", "converter_fingerprint")
            .create()
        try await ProviderGlobalScopeSchema.protect(table: "provider_conversion_instants", on: database)
    }

    func revert(on database: any Database) async throws {
        try await database.transaction { transaction in
            let tables = [
                "provider_worker_states", "provider_conversion_instants", "provider_staged_records", "provider_query_coverage",
                "provider_checkpoints",
                "provider_link_intents",
                "provider_connections", "provider_global_scopes"
            ]
            let sql = try ProviderSQL.sql(transaction)
            for table in tables {
                let row = try await sql.raw("SELECT 1 FROM \(ident: table) LIMIT 1").first()
                guard row == nil else { throw ProviderFailure.fenced }
            }
            try await sql.raw("DROP INDEX provider_retained_outputs").run()
            for table in tables { try await transaction.schema(table).delete() }
            try await transaction.schema("provider_dispatch_budgets").delete()
        }
    }
}
