//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import SQLKit
import Testing
@testable import TroveServer


struct ClinicalRecordSchemaTests {
    @Test(arguments: ["00", "-1", "+1", "1.0", "1e2", "１", String(repeating: "9", count: 4097)])
    func invalidVersionFailsBeforeAnyCustody(version: String) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                await #expect {
                    try await ClinicalEventStore(database: app.db).accept(
                        ClinicalRecordStoreTests.event(source: fixture.source, sequence: 1, version: version),
                        sourceID: fixture.source.id,
                        targets: fixture.targets
                    )
                } throws: { ($0 as? ServerError)?.status.code == 400 }
            }
            try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
        }
    }

    @Test(arguments: ["", String(repeating: "a", count: 513), String(repeating: "é", count: 257)])
    func completeIdentityIndexesAreByteBounded(value: String) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let sql = try #require(app.db as? any SQLDatabase)
            await #expect {
                try await sql.raw("""
                    INSERT INTO clinical_source_records (id, source_id, identifier_system, identifier_value)
                    VALUES (\(bind: UUID()), \(bind: fixture.source.id), 'urn:source-record', \(bind: value))
                    """)
                    .run()
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
        }
    }

    @Test(arguments: ["00", "-1", "+1", "1.0", "1e2", "１", String(repeating: "9", count: 4097)])
    func databaseAlsoRejectsNoncanonicalWriterVersions(version: String) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await ClinicalEventStore(database: app.db).accept(
                    ClinicalRecordStoreTests.event(source: fixture.source, sequence: 1, version: "0"),
                    sourceID: fixture.source.id,
                    targets: fixture.targets
                )
            }
            await #expect {
                try await app.db.transaction { transaction in
                    let sql = try #require(transaction as? any SQLDatabase)
                    let eventID = UUID()
                    try await sql.raw("""
                        INSERT INTO clinical_events (id, source_id, identifier_system, identifier_value, raw_bytes, raw_sha256,
                            validator_identity, target_intent, received_at, node_count)
                        SELECT \(bind: eventID), source_id, identifier_system, 'new-event', raw_bytes, raw_sha256,
                            validator_identity, target_intent, received_at, node_count FROM clinical_events
                        """)
                        .run()
                    try await sql.raw("""
                        INSERT INTO clinical_record_events (event_id, source_id, record_id, kind, writer_system, writer_value, writer_version)
                        SELECT \(bind: eventID), source_id, record_id, 'active', writer_system, writer_value, \(bind: version)
                        FROM clinical_record_events
                        """)
                        .run()
                }
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            try await ClinicalEventStoreTests.expectRows(events: 1, nodes: 2, facts: 1, grants: 2, on: app.db)
        }
    }

    @Test
    func byteBoundaryFitsAndDistinctCompleteIdentifiersRemainDistinct() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let sql = try #require(app.db as? any SQLDatabase)
            for value in [String(repeating: "é", count: 256), "Case", "case", "é", "e\u{301}"] {
                try await sql.raw("""
                    INSERT INTO clinical_source_records (id, source_id, identifier_system, identifier_value)
                    VALUES (\(bind: UUID()), \(bind: fixture.source.id), \(bind: String(repeating: "s", count: 512)), \(bind: value))
                    """)
                    .run()
            }
            let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM clinical_source_records").first())
            #expect(try row.decode(column: "count", as: Int.self) == 5)
        }
    }

    @Test
    func exactNodeCannotBeAttachedToAnotherEventsRecord() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let receipts = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                let first = try await store.accept(
                    ClinicalRecordStoreTests.event(source: fixture.source, sequence: 1, version: "1"),
                    sourceID: fixture.source.id,
                    targets: fixture.targets
                )
                let secondEvent = ClinicalRecordStoreTests.event(
                    source: fixture.source, sequence: 2, version: "1", record: "another", outputs: ["other"]
                )
                let second = try await store.accept(
                    secondEvent,
                    sourceID: fixture.source.id,
                    targets: fixture.targets(for: secondEvent)
                )
                return (first, second)
            }
            let sql = try #require(app.db as? any SQLDatabase)
            // Unused patient node in event two avoids a duplicate node/output uniqueness failure.
            // Its event cannot claim event one's record and binding, even within the same source.
            await #expect {
                try await sql.raw("""
                    INSERT INTO clinical_point_facts (node_id, source_id, event_id, record_id, output_binding_id, profile, effective_at,
                        quantity_value, quantity_system, quantity_code, code_system, code)
                    SELECT n.id, n.source_id, n.event_id, f.record_id, f.output_binding_id, f.profile, f.effective_at,
                        f.quantity_value, f.quantity_system, f.quantity_code, f.code_system, f.code
                    FROM clinical_point_facts f CROSS JOIN clinical_event_nodes n
                    WHERE f.event_id = \(bind: receipts.0.eventID) AND n.event_id = \(bind: receipts.1.eventID) AND n.ordinal = 0
                    """)
                    .run()
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            try await ClinicalEventStoreTests.expectRows(events: 2, nodes: 4, facts: 2, grants: 4, on: app.db)
        }
    }
}
