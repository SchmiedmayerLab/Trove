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


/// Synthetic admitted projections test actual SQL persistence; full graph/validator coverage is separate.
struct ClinicalRecordStoreTests {
    @Test(arguments: [[1, 2, 3], [1, 3, 2], [2, 1, 3], [2, 3, 1], [3, 1, 2], [3, 2, 1]])
    func uniqueHigherRevisionSurvivesOlderConflictInEveryOrder(order: [Int]) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                let events = [
                    Self.event(source: fixture.source, sequence: 1, version: "9007199254740992"),
                    Self.event(source: fixture.source, sequence: 2, version: "9007199254740992"),
                    Self.event(source: fixture.source, sequence: 3, version: "18446744073709551616")
                ]
                var receipts: [Int: ClinicalEventReceipt] = [:]
                for index in order {
                    receipts[index] = try await store.accept(
                        events[index - 1], sourceID: fixture.source.id, targets: fixture.targets(for: events[index - 1])
                    )
                }
                let highest = try #require(receipts[3])
                #expect(try await Self.current(on: app.db) == [highest.eventID])
                for index in order {
                    let replay = try await store.accept(
                        events[index - 1], sourceID: fixture.source.id, targets: fixture.targets(for: events[index - 1])
                    )
                    #expect(replay == receipts[index])
                }
                #expect(try await Self.current(on: app.db) == [highest.eventID])
                try await ClinicalEventStoreTests.expectRows(events: 3, nodes: 6, facts: 3, grants: 6, on: app.db)
                #expect(try await Self.count("clinical_source_records", on: app.db) == 1)
                #expect(try await Self.count("clinical_output_bindings", on: app.db) == 1)
            }
        }
    }

    @Test(arguments: ["equal", "missing", "different"])
    func competingEvidenceNeverUsesArrivalOrderToDisclose(kind: String) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                let first = Self.event(source: fixture.source, sequence: 1, version: "10")
                let second = Self.event(
                    source: fixture.source,
                    sequence: 2,
                    version: kind == "missing" ? nil : kind == "equal" ? "10" : "999",
                    writer: kind == "missing" ? nil : kind == "different" ? "other" : "writer"
                )
                _ = try await store.accept(first, sourceID: fixture.source.id, targets: fixture.targets(for: first))
                _ = try await store.accept(second, sourceID: fixture.source.id, targets: fixture.targets(for: second))
                #expect(try await Self.current(on: app.db).isEmpty)
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 0)
                try await ClinicalEventStoreTests.expectRows(events: 2, nodes: 4, facts: 2, grants: 4, on: app.db)
            }
        }
    }

    @Test
    func completeMembershipAndStudyGrantsCannotFallBackToOldChildren() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                let first = Self.event(source: fixture.source, sequence: 1, version: "9", outputs: ["primary", "secondary"])
                let second = Self.event(source: fixture.source, sequence: 2, version: "10")
                let third = Self.event(source: fixture.source, sequence: 3, version: "11", outputs: ["primary", "secondary"])
                _ = try await store.accept(first, sourceID: fixture.source.id, targets: fixture.targets(for: first, studies: [0]))
                let next = try await store.accept(second, sourceID: fixture.source.id, targets: fixture.targets(for: second, studies: [1]))
                #expect(try await Self.current(on: app.db) == [next.eventID])
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 0)
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[1]) == 1)
                let last = try await store.accept(third, sourceID: fixture.source.id, targets: fixture.targets(for: third, studies: [0]))
                #expect(try await Self.current(on: app.db) == [last.eventID])
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 2)
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[1]) == 0)
                try await ClinicalEventStoreTests.expectRows(events: 3, nodes: 8, facts: 5, grants: 5, on: app.db)
                #expect(try await Self.count("clinical_output_bindings", on: app.db) == 2)
            }
        }
    }

    @Test
    func concurrentContradictoryBindingsCommitOnlyOneCompleteClaim() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                async let first = Self.attempt(store, event: Self.event(source: fixture.source, sequence: 1, version: "1"), fixture: fixture)
                async let second = Self.attempt(
                    store, event: Self.event(source: fixture.source, sequence: 2, version: "2", record: "contradiction"), fixture: fixture
                )
                let outcomes = try await [first, second]
                #expect(outcomes.filter { $0 }.count == 1)
                try await ClinicalEventStoreTests.expectRows(events: 1, nodes: 2, facts: 1, grants: 2, on: app.db)
                #expect(try await Self.count("clinical_source_records", on: app.db) == 1)
                #expect(try await Self.count("clinical_record_events", on: app.db) == 1)
                #expect(try await Self.count("clinical_output_bindings", on: app.db) == 1)
            }
        }
    }

    @Test
    func reopenedDatabaseRetainsSelectionAndExactIndependentGrants() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let first = Self.event(source: fixture.source, sequence: 1, version: "9", outputs: ["primary", "secondary"])
            let second = Self.event(source: fixture.source, sequence: 2, version: "10")
            let expected = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                _ = try await store.accept(first, sourceID: fixture.source.id, targets: fixture.targets(for: first, studies: [0]))
                return try await store.accept(second, sourceID: fixture.source.id, targets: fixture.targets(for: second, studies: [1]))
            }
            try await TestDatabase.withRestartedApplication(app) { reopened in
                let store = ClinicalEventStore(database: reopened.db)
                #expect(try await Self.current(on: reopened.db) == [expected.eventID])
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 0)
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[1]) == 1)
                try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                    let retry = try await store.accept(second, sourceID: fixture.source.id, targets: fixture.targets(for: second, studies: [1]))
                    #expect(retry == expected)
                }
                try await ClinicalEventStoreTests.expectRows(events: 2, nodes: 5, facts: 3, grants: 3, on: reopened.db)
            }
        }
    }

    @Test(arguments: ["clinical_source_records", "clinical_record_events", "clinical_output_bindings"])
    func revisionIdentityIsAppendOnly(table: String) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await ClinicalEventStore(database: app.db).accept(
                    Self.event(source: fixture.source, sequence: 1, version: "1"), sourceID: fixture.source.id, targets: fixture.targets
                )
            }
            let sql = try #require(app.db as? any SQLDatabase)
            await #expect {
                try await sql.raw("UPDATE \(ident: table) SET source_id = source_id").run()
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            await #expect {
                try await sql.raw("DELETE FROM \(ident: table)").run()
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            #expect(try await Self.count(table, on: app.db) == 1)
        }
    }

    @Test
    func auditFailureLeavesNoRecordOrOutputReservation() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("DROP TABLE audit_events").run()
            await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                await #expect(throws: (any Error).self) {
                    try await ClinicalEventStore(database: app.db).accept(
                        Self.event(source: fixture.source, sequence: 1, version: "1"),
                        sourceID: fixture.source.id,
                        targets: fixture.targets
                    )
                }
            }
            #expect(try await Self.count("clinical_source_records", on: app.db) == 0)
            #expect(try await Self.count("clinical_record_events", on: app.db) == 0)
            #expect(try await Self.count("clinical_output_bindings", on: app.db) == 0)
            try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
        }
    }
}


extension ClinicalRecordStoreTests {
    static func event(
        source: SourceBinding, sequence: Int, version: String?, writer: String? = "writer", record: String = "record", outputs: [String] = ["primary"]
    ) -> ValidatedExchangeEvent {
        let base = ClinicalEventStoreTests.event(source: source, sequence: sequence)
        let nodes = [base.nodes[0]] + outputs.enumerated().map {
            ValidatedExchangeEvent.Node(
                ordinal: $0.offset + 1,
                fullURL: $0.element == "primary" ? "urn:uuid:point" : "urn:point:" + $0.element,
                resourceType: "Observation"
            )
        }
        let points = outputs.map { output in
            ValidatedExchangeEvent.PointOutput(
                fullURL: output == "primary" ? "urn:uuid:point" : "urn:point:" + output,
                profile: CollectionRequirement.supportedProfile,
                effectiveAt: Date(),
                sourceRecordIdentifier: .init(system: "urn:source-record", value: record),
                sourceOutputIdentifier: .init(system: "urn:source-output", value: output),
                writerIdentifier: writer.map { .init(system: "urn:writer-record", value: $0) },
                writerVersion: version,
                quantityValue: "72",
                quantitySystem: "http://unitsofmeasure.org",
                quantityCode: "/min",
                codeSystem: "http://loinc.org",
                code: "8867-4"
            )
        }
        return .init(
            rawBytes: base.rawBytes,
            validatorIdentity: base.validatorIdentity,
            eventIdentifierSystem: base.eventIdentifierSystem,
            eventIdentifierValue: base.eventIdentifierValue,
            producerInstance: base.producerInstance,
            participants: base.participants,
            nodes: nodes,
            outputs: points
        )
    }

    private static func current(on database: any Database) async throws -> [UUID] {
        let sql = try #require(database as? any SQLDatabase)
        return try await sql.raw("""
            SELECT r.event_id FROM clinical_record_events r WHERE \(ClinicalRecordStore.currentPredicate(on: sql))
            """)
            .all()
            .map { try $0.decode(column: "event_id", as: UUID.self) }
    }

    private static func count(_ table: String, on database: any Database) async throws -> Int {
        let sql = try #require(database as? any SQLDatabase)
        let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM \(ident: table)").first())
        return try row.decode(column: "count", as: Int.self)
    }

    private static func attempt(
        _ store: ClinicalEventStore, event: ValidatedExchangeEvent, fixture: ClinicalEventStoreTests.Fixture
    ) async throws -> Bool {
        do {
            _ = try await store.accept(event, sourceID: fixture.source.id, targets: fixture.targets(for: event))
            return true
        } catch let error as ServerError where error.status.code == 409 {
            return false
        }
    }
}
