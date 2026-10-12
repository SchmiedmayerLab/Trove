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


/// Actual transactions with synthetic admitted projections; graph/HTTP validation is separate.
struct ClinicalRetractionTests {
    @Test(arguments: [[1, 2, 3], [2, 1, 3], [3, 2, 1], [3, 1, 2], [1, 3, 2], [2, 3, 1]])
    func tombstoneSuppressesEveryVersionInAnyArrivalOrderAndAfterReopening(order: [Int]) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let events = [
                ClinicalRecordStoreTests.event(source: fixture.source, sequence: 1, version: "1"),
                ClinicalRecordStoreTests.event(source: fixture.source, sequence: 2, version: "2"),
                Self.retraction(source: fixture.source)
            ]
            let receipts = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                var receipts: [Int: ClinicalEventReceipt] = [:]
                for index in order {
                    let event = events[index - 1]
                    receipts[index] = try await store.accept(
                        event, sourceID: fixture.source.id, targets: index == 3 ? [] : fixture.targets(for: event, studies: [0])
                    )
                    if receipts[3] != nil { #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 0) }
                    #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[1]) == 0)
                }
                return receipts
            }
            try await TestDatabase.withRestartedApplication(app) { reopened in
                try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                    let store = ClinicalEventStore(database: reopened.db)
                    for index in order {
                        let event = events[index - 1]
                        let replay = try await store.accept(
                            event, sourceID: fixture.source.id, targets: index == 3 ? [] : fixture.targets(for: event, studies: [0])
                        )
                        #expect(replay == receipts[index])
                    }
                    #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 0)
                    #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0], currentOnly: false) == 0)
                    try await ClinicalEventStoreTests.expectRows(events: 3, nodes: 5, facts: 2, grants: 2, on: reopened.db)
                    #expect(try await Self.count("clinical_output_retractions", on: reopened.db) == 1)
                }
            }
        }
    }

    @Test
    func retractionIsOutputScopedAndDoesNotCrossSourceBindings() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let other = try await SourceBindingService(database: app.db).register(registrationID: UUID())
                let store = ClinicalEventStore(database: app.db)
                let first = ClinicalRecordStoreTests.event(source: fixture.source, sequence: 1, version: "1", outputs: ["primary", "secondary"])
                let second = ClinicalRecordStoreTests.event(source: other, sequence: 1, version: "1")
                _ = try await store.accept(first, sourceID: fixture.source.id, targets: fixture.targets(for: first))
                _ = try await store.accept(second, sourceID: other.id, targets: fixture.targets(for: second))
                _ = try await store.accept(Self.retraction(source: fixture.source), sourceID: fixture.source.id, targets: [])
                for study in fixture.studyIDs { #expect(try await store.effectiveGrantCount(studyID: study) == 2) }
                try await ClinicalEventStoreTests.expectRows(events: 3, nodes: 6, facts: 3, grants: 6, on: app.db)
            }
        }
    }

    @Test(arguments: [true, false])
    func contradictoryFirstClaimsRejectAtomically(retractionFirst: Bool) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let active = ClinicalRecordStoreTests.event(source: fixture.source, sequence: 1, version: "1", record: "contradiction")
            let retraction = Self.retraction(source: fixture.source)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                _ = try await store.accept(
                    retractionFirst ? retraction : active,
                    sourceID: fixture.source.id,
                    targets: retractionFirst ? [] : fixture.targets
                )
                await #expect {
                    try await store.accept(
                        retractionFirst ? active : retraction,
                        sourceID: fixture.source.id,
                        targets: retractionFirst ? fixture.targets : []
                    )
                } throws: { ($0 as? ServerError)?.status.code == 409 }
                #expect(try await Self.count("clinical_events", on: app.db) == 1)
                #expect(try await Self.count("clinical_source_records", on: app.db) == 1)
                #expect(try await Self.count("clinical_output_bindings", on: app.db) == 1)
                #expect(try await Self.count("clinical_output_retractions", on: app.db) == (retractionFirst ? 1 : 0))
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == (retractionFirst ? 0 : 1))
            }
        }
    }

    @Test
    func withdrawalDoesNotBlockRestrictionButRevocationDoes() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                for id in fixture.enrollmentIDs { _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: id) }
                let store = ClinicalEventStore(database: app.db)
                _ = try await store.accept(Self.retraction(source: fixture.source), sourceID: fixture.source.id, targets: [])
                _ = try await SourceBindingService(database: app.db).revoke(id: fixture.source.id)
                await #expect {
                    try await store.accept(Self.retraction(source: fixture.source, sequence: 4), sourceID: fixture.source.id, targets: [])
                } throws: { ($0 as? ServerError)?.status.code == 409 }
                try await ClinicalEventStoreTests.expectRows(events: 1, nodes: 1, facts: 0, grants: 0, on: app.db)
            }
        }
    }

    @Test
    func concurrentCrossKindClaimsCommitOnlyOneBinding() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                let active = ClinicalRecordStoreTests.event(source: fixture.source, sequence: 1, version: "1", record: "contradiction")
                async let first = Self.attempt(store, event: active, sourceID: fixture.source.id, targets: fixture.targets)
                async let second = Self.attempt(store, event: Self.retraction(source: fixture.source), sourceID: fixture.source.id, targets: [])
                let outcomes = try await [first, second]
                #expect(outcomes.filter { $0 }.count == 1)
                #expect(try await Self.count("clinical_events", on: app.db) == 1)
                #expect(try await Self.count("clinical_output_bindings", on: app.db) == 1)
                #expect(try await Self.count("clinical_source_records", on: app.db) == 1)
            }
        }
    }

    @Test
    func foreignParticipantCannotRetractAnOwnedSource() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let foreign = AuthContext(
                issuer: TestApp.issuer,
                subject: "foreign",
                email: "foreign@example.test",
                roles: [TestApp.participantRole],
                groups: [],
                researcherRole: TestApp.researcherRole,
                participantRole: TestApp.participantRole
            )
            await AuthContext.$current.withValue(foreign) {
                await #expect {
                    try await ClinicalEventStore(database: app.db).accept(
                        Self.retraction(source: fixture.source), sourceID: fixture.source.id, targets: []
                    )
                } throws: { ($0 as? ServerError)?.status.code == 404 }
            }
            #expect(try await Self.count("clinical_events", on: app.db) == 0)
        }
    }

    @Test
    func tombstoneIsAppendOnlyAndCannotBeClaimedByAnActiveEvent() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                _ = try await store.accept(
                    ClinicalRecordStoreTests.event(source: fixture.source, sequence: 1, version: "1"),
                    sourceID: fixture.source.id,
                    targets: fixture.targets
                )
                _ = try await store.accept(Self.retraction(source: fixture.source), sourceID: fixture.source.id, targets: [])
            }
            let sql = try #require(app.db as? any SQLDatabase)
            for statement in ["UPDATE clinical_output_retractions SET kind = kind", "DELETE FROM clinical_output_retractions"] {
                await #expect { try await sql.raw("\(unsafeRaw: statement)").run() }
                    throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            }
            await #expect {
                try await sql.raw("""
                    INSERT INTO clinical_output_retractions (event_id, source_id, record_id, output_binding_id, kind)
                    SELECT event_id, source_id, record_id, output_binding_id, 'retraction' FROM clinical_point_facts
                    """)
                    .run()
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            #expect(try await Self.count("clinical_output_retractions", on: app.db) == 1)
        }
    }

    @Test
    func lifecycleKindCannotBypassCollectionOrCreateGrants() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                await #expect {
                    try await store.accept(ClinicalEventStoreTests.event(source: fixture.source), sourceID: fixture.source.id, targets: [])
                } throws: { ($0 as? ServerError)?.status.code == 400 }
                await #expect {
                    try await store.accept(Self.retraction(source: fixture.source), sourceID: fixture.source.id, targets: fixture.targets)
                } throws: { ($0 as? ServerError)?.status.code == 400 }
                try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
            }
        }
    }

    @Test
    func auditFailureLeavesNoTombstoneOrIdentityReservation() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("DROP TABLE audit_events").run()
            await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                await #expect(throws: (any Error).self) {
                    try await ClinicalEventStore(database: app.db).accept(
                        Self.retraction(source: fixture.source), sourceID: fixture.source.id, targets: []
                    )
                }
            }
            let tables = [
                "clinical_events", "clinical_source_records", "clinical_record_events", "clinical_output_bindings", "clinical_output_retractions"
            ]
            for table in tables {
                #expect(try await Self.count(table, on: app.db) == 0)
            }
        }
    }
}


extension ClinicalRetractionTests {
    private static func attempt(
        _ store: ClinicalEventStore, event: ValidatedExchangeEvent, sourceID: UUID, targets: [ClinicalEventTarget]
    ) async throws -> Bool {
        do {
            _ = try await store.accept(event, sourceID: sourceID, targets: targets)
            return true
        } catch let error as ServerError where error.status.code == 409 {
            return false
        }
    }

    static func retraction(source: SourceBinding, sequence: Int = 3) -> ValidatedExchangeEvent {
        let base = ClinicalRecordStoreTests.event(source: source, sequence: sequence, version: nil, writer: nil)
        return .init(
            rawBytes: base.rawBytes,
            validatorIdentity: base.validatorIdentity,
            eventIdentifierSystem: base.eventIdentifierSystem,
            eventIdentifierValue: base.eventIdentifierValue,
            producerInstance: base.producerInstance,
            deploymentIdentifiers: base.deploymentIdentifiers,
            participants: [],
            nodes: [.init(ordinal: 0, fullURL: "urn:uuid:retraction", resourceType: "Provenance")],
            outputs: [],
            retraction: .init(
                sourceRecordIdentifier: base.outputs[0].sourceRecordIdentifier,
                outputIdentifiers: [base.outputs[0].sourceOutputIdentifier]
            )
        )
    }

    private static func count(_ table: String, on database: any Database) async throws -> Int {
        let sql = try #require(database as? any SQLDatabase)
        let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM \(ident: table)").first())
        return try row.decode(column: "count", as: Int.self)
    }
}
