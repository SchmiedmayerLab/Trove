//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import FluentPostgresDriver
import FluentSQLiteDriver
import Foundation
import SQLKit
import Testing
@testable import TroveServer


/// Tests storage shape with explicitly synthetic prevalidated projections, not
/// FHIR conformance or permission to collect additional profiles.
struct ClinicalObservationFactTests {
    @Test(arguments: [
        ClinicalOutputValue.quantity(value: "72.123456789012345678901", system: "http://unitsofmeasure.org", code: "/min"),
        .coded(system: "urn:synthetic:sleep-stage", code: "deep"),
        .components
    ])
    func retainsTypedFactsAndOriginalBytes(value: ClinicalOutputValue) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let event = try ClinicalEventStoreTests.event(source: fixture.source, value: value)
            let receipt = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await ClinicalEventStore(database: app.db).accept(
                    event, sourceID: fixture.source.id, targets: fixture.targets, installation: fixture.installation
                )
            }
            let sql = try #require(app.db as? any SQLDatabase)
            let row = try #require(try await sql.raw("""
                SELECT f.value_kind, f.quantity_value, f.quantity_system, f.quantity_code,
                    f.value_code_system, f.value_code, f.effective_end, e.raw_bytes
                FROM clinical_point_facts f JOIN clinical_events e ON e.id = f.event_id
                WHERE f.event_id = \(bind: receipt.eventID)
                """)
                .first())
            #expect(try row.decode(column: "value_kind", as: String.self) == value.kind)
            #expect(try row.decode(column: "quantity_value", as: String?.self) == value.quantityValue)
            #expect(try row.decode(column: "quantity_system", as: String?.self) == value.quantitySystem)
            #expect(try row.decode(column: "quantity_code", as: String?.self) == value.quantityCode)
            #expect(try row.decode(column: "value_code_system", as: String?.self) == value.codingSystem)
            #expect(try row.decode(column: "value_code", as: String?.self) == value.codingCode)
            #expect(try row.decode(column: "effective_end", as: Date?.self) == nil)
            #expect(try row.decode(column: "raw_bytes", as: Data.self) == event.rawBytes)
        }
    }

    @Test(arguments: ["unknown-kind", "quantity-with-coding", "coded-with-quantity", "components-with-quantity", "reversed-interval"])
    func databaseRefusesInconsistentFacts(corruption: String) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let event = try ClinicalEventStoreTests.event(source: fixture.source)
            let receipt = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await ClinicalEventStore(database: app.db).accept(
                    event, sourceID: fixture.source.id, targets: fixture.targets, installation: fixture.installation
                )
            }
            let sql = try #require(app.db as? any SQLDatabase)
            let kind = corruption == "coded-with-quantity" ? "coded" : corruption == "components-with-quantity" ? "components"
                : corruption == "unknown-kind" ? "unknown" : "quantity"
            let coding: String? = corruption == "quantity-with-coding" || corruption == "coded-with-quantity" ? "deep" : nil
            let end: Date? = corruption == "reversed-interval" ? .distantPast : nil
            await #expect {
                // An unused node avoids a primary-key failure. Assert CHECK specifically,
                // so a foreign-key or uniqueness error cannot satisfy this regression.
                try await sql.raw("""
                    INSERT INTO clinical_point_facts (node_id, source_id, event_id, record_id, output_binding_id,
                        profile, effective_at, effective_seconds, effective_fraction, effective_end,
                        value_kind, quantity_value, quantity_system, quantity_code,
                        value_code_system, value_code, code_system, code)
                    SELECT n.id, n.source_id, f.event_id, f.record_id, f.output_binding_id,
                        f.profile, f.effective_at, f.effective_seconds, f.effective_fraction, \(bind: end),
                        \(bind: kind), f.quantity_value, f.quantity_system, f.quantity_code,
                        \(bind: coding), \(bind: coding), f.code_system, f.code
                    FROM clinical_event_nodes n JOIN clinical_point_facts f ON f.event_id = n.event_id
                    WHERE n.event_id = \(bind: receipt.eventID) AND n.ordinal = 0
                    """)
                    .run()
            } throws: {
                ($0 as? PSQLError)?.serverInfo?[.sqlState] == "23514"
                    || ($0 as? SQLiteError)?.reason == .constraintCheckFailed
            }
            try await ClinicalEventStoreTests.expectRows(events: 1, nodes: 2, facts: 1, grants: 2, on: app.db)
        }
    }
}
