//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import FluentPostgresDriver
import SQLKit


struct CreateFHIRResources: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("fhir_resources")
            .field("participant_id", .uuid, .required)
            .field("resource_type", .string, .required)
            .field("time", .datetime, .required)
            .field("external_id", .string, .required)
            .field("code", .string)
            .field("code_system", .string)
            .field("value", .double)
            .field("value_code", .string)
            .field("value_system", .string)
            .field("resource", .json, .required)
            .compositeIdentifier(over: "participant_id", "time", "external_id")
            .create()

        // Hypertable / compression extensions are Timescale-only. On sqlite (tests)
        // we keep the plain table without the time-series machinery.
        guard database is any PostgresDatabase, let sql = database as? any SQLDatabase else {
            return
        }

        try await sql.raw("""
            SELECT create_hypertable('fhir_resources', 'time', chunk_time_interval => INTERVAL '7 days')
            """)
            .run()

        try await sql.raw("""
            CREATE INDEX idx_fhir_resources_participant_type_code_time
                ON fhir_resources (participant_id, resource_type, code_system, code, time DESC)
            """)
            .run()

        try await sql.raw("""
            ALTER TABLE fhir_resources SET (
                timescaledb.compress,
                timescaledb.compress_segmentby = 'participant_id, resource_type, code_system, code',
                timescaledb.compress_orderby   = 'time DESC'
            )
            """)
            .run()

        try await sql.raw("""
            SELECT add_compression_policy('fhir_resources', INTERVAL '7 days')
            """)
            .run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("fhir_resources").delete()
    }
}
