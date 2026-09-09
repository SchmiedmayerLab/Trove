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
import TroveAPIServer
@testable import TroveServer


struct ReceiverRevisionAssertions: Sendable {
    let fixture: ClinicalEventStoreTests.Fixture
    let prepared: [String: ReceiverRevisionCorpus.PreparedEvent]
    let receipts: [String: Components.Schemas.EventReceipt]

    func keys(_ aliases: [String]) -> Set<String> {
        Set(aliases.compactMap { alias in
            for (name, event) in prepared {
                if let url = event.addresses[alias], let receipt = receipts[name] {
                    return Self.key(event: receipt.eventId, url: url)
                }
            }
            Issue.record("Missing exact output alias: \(alias)")
            return nil
        })
    }

    @discardableResult
    func check(_ expected: ReceiverRevisionCorpus.State, on database: any Database) async throws -> Set<String> {
        let sql = try #require(database as? any SQLDatabase)
        let history = try await sql.raw("SELECT id, raw_bytes FROM clinical_events").all()
        let ids = try Set(history.map { try $0.decode(column: "id", as: UUID.self).uuidString.lowercased() })
        #expect(ids == eventIDs(expected.history))
        for name in expected.history {
            let receipt = try #require(receipts[name])
            let row = try #require(try history.first {
                try $0.decode(column: "id", as: UUID.self).uuidString.lowercased() == receipt.eventId.lowercased()
            })
            #expect(try row.decode(column: "raw_bytes", as: Data.self) == prepared[name]?.bytes)
        }
        let versions = try await points(where: "1 = 1", on: sql)
        #expect(versions == keys(expected.versions))
        let selection = ClinicalRecordStore.currentPredicate(on: sql)
        #expect(try await points(where: selection, on: sql) == keys(expected.current))
        let studyID = fixture.studyIDs[0]
        let visible = try await points(where: """
            \(selection) AND EXISTS (SELECT 1 FROM study_data_grants g
                JOIN enrollments e ON e.id = g.enrollment_id
                WHERE g.node_id = f.node_id AND g.study_id = \(bind: studyID) AND e.withdrawn_at IS NULL)
            """, on: sql)
        #expect(visible == keys(expected.visible))
        let store = ClinicalEventStore(database: database)
        #expect(try await store.effectiveGrantCount(studyID: studyID) == expected.visible.count)
        #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[1]) == 0)
        #expect(try await conflictingEvidence(on: sql) == eventIDs(expected.conflicts))
        return visible
    }
}


extension ReceiverRevisionAssertions {
    private static func key(event: String, url: String) -> String { "\(event.lowercased())\n\(url)" }

    private func eventIDs(_ names: [String]) -> Set<String> {
        Set(names.compactMap { name in
            guard let receipt = receipts[name] else {
                Issue.record("Missing receipt for corpus event: \(name)")
                return nil
            }
            return receipt.eventId.lowercased()
        })
    }

    private func points(where predicate: SQLQueryString, on sql: any SQLDatabase) async throws -> Set<String> {
        let rows = try await sql.raw("""
            SELECT f.event_id, n.full_url FROM clinical_point_facts f
            JOIN clinical_event_nodes n ON n.id = f.node_id
            JOIN clinical_record_events r ON r.event_id = f.event_id WHERE \(predicate)
            """)
            .all()
        return try Set(rows.map {
            try Self.key(event: $0.decode(column: "event_id", as: UUID.self).uuidString, url: $0.decode(column: "full_url", as: String.self))
        })
    }

    /// Inspects retained evidence, not a public conflict-reporting API or a second selector.
    /// A later unique maximum must not erase earlier equal/incomparable claims.
    private func conflictingEvidence(on sql: any SQLDatabase) async throws -> Set<String> {
        let rows = try await sql.raw("""
            SELECT r.event_id FROM clinical_record_events r WHERE EXISTS (
                SELECT 1 FROM clinical_record_events other WHERE other.record_id = r.record_id AND other.event_id <> r.event_id
                AND (r.writer_version IS NULL OR other.writer_version IS NULL
                    OR r.writer_system <> other.writer_system OR r.writer_value <> other.writer_value
                    OR r.writer_version = other.writer_version))
            """)
            .all()
        return try Set(rows.map { try $0.decode(column: "event_id", as: UUID.self).uuidString.lowercased() })
    }
}
