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


/// Actual custody and authorization with local graph fixtures; full-IG validation is exercised separately.
struct ClinicalRecordRepresentationTests {
    @Test(arguments: [false, true])
    func variantsRetainExactReceiptsWithoutDuplicatingFactsOrGrants(formattingOnly: Bool) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let original = try Self.project(LocalPointEventFixture.bytes(source: fixture.source))
            let updated = try Self.project(formattingOnly
                ? original.rawBytes + Data(" ".utf8) : RecordRepresentationFixture.enrollment(original.rawBytes))
            let targets = fixture.targets(for: original)
            let receipts = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                let first = try await store.accept(original, sourceID: fixture.source.id, targets: targets)
                let second = try await store.accept(updated, sourceID: fixture.source.id, targets: targets)
                #expect(first.eventID == second.eventID)
                #expect(first.payloadSHA256 != second.payloadSHA256)
                #expect(first.targetIntentSHA256 == second.targetIntentSHA256)
                _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: fixture.enrollmentIDs[0])
                return [first, second]
            }
            try await ClinicalEventStoreTests.expectRows(events: 1, nodes: original.nodes.count, facts: 1, grants: 2, on: app.db)
            #expect(try await Self.retained(on: app.db) == [updated.rawBytes])
            try await TestDatabase.withRestartedApplication(app) { reopened in
                try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                    let store = ClinicalEventStore(database: reopened.db)
                    for (event, receipt) in zip([original, updated], receipts) {
                        #expect(try await store.accept(event, sourceID: fixture.source.id, targets: targets) == receipt)
                    }
                    _ = try await SourceBindingService(database: reopened.db).revoke(id: fixture.source.id)
                    for receipt in receipts {
                        let lookup = try Self.lookup(receipt, targets: targets)
                        #expect(try await ClinicalEventReceiptStore(database: reopened.db).lookup(lookup, sourceID: fixture.source.id) == receipt)
                    }
                    #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 0)
                    #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[1]) == 1)
                }
            }
        }
    }

    @Test(arguments: ["clinical", "context-key", "intent", "withdrawal", "audit"])
    func refusedVariantDoesNotChangeRetainedState(reason: String) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let original = try Self.project(LocalPointEventFixture.bytes(source: fixture.source))
            var updated = try Self.project(RecordRepresentationFixture.enrollment(original.rawBytes, rekey: reason != "context-key"))
            var targets = fixture.targets(for: original)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                let first = try await store.accept(original, sourceID: fixture.source.id, targets: targets)
                switch reason {
                case "clinical":
                    let string = try #require(String(data: updated.rawBytes, encoding: .utf8))
                    updated = try Self.project(Data(string.replacingOccurrences(of: "\"value\":72", with: "\"value\":73").utf8))
                case "intent": targets.removeLast()
                case "withdrawal":
                    for enrollment in fixture.enrollmentIDs {
                        _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: enrollment)
                    }
                    #expect(try await store.accept(original, sourceID: fixture.source.id, targets: targets) == first)
                case "audit": try await app.db.schema("audit_events").delete()
                default: break
                }
                await #expect(throws: (any Error).self) {
                    try await store.accept(updated, sourceID: fixture.source.id, targets: targets)
                }
            }
            #expect(try await Self.retained(on: app.db).isEmpty)
            try await ClinicalEventStoreTests.expectRows(events: 1, nodes: original.nodes.count, facts: 1, grants: 2, on: app.db)
        }
    }

    @Test
    func additionalCustodyIsAppendOnly() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let original = try Self.project(LocalPointEventFixture.bytes(source: fixture.source))
            let updated = try Self.project(RecordRepresentationFixture.enrollment(original.rawBytes))
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                let targets = fixture.targets(for: original)
                _ = try await store.accept(original, sourceID: fixture.source.id, targets: targets)
                _ = try await store.accept(updated, sourceID: fixture.source.id, targets: targets)
            }
            let sql = try #require(app.db as? any SQLDatabase)
            await #expect {
                try await sql.raw("UPDATE clinical_event_representations SET raw_sha256 = raw_sha256").run()
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            await #expect {
                try await sql.raw("DELETE FROM clinical_event_representations").run()
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            #expect(try await Self.retained(on: app.db) == [updated.rawBytes])
        }
    }

    @Test
    func snapshotFirstSeenInAdditionalRepresentationCannotLaterChangeUnderItsKey() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let original = try Self.project(LocalPointEventFixture.bytes(source: fixture.source))
            let updated = try Self.project(RecordRepresentationFixture.enrollment(original.rawBytes))
            let conflicting = try Self.project(RecordRepresentationFixture.enrollment(updated.rawBytes, status: "on-study", rekey: false))
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                let targets = fixture.targets(for: original)
                _ = try await store.accept(original, sourceID: fixture.source.id, targets: targets)
                _ = try await store.accept(updated, sourceID: fixture.source.id, targets: targets)
                await #expect {
                    try await store.accept(conflicting, sourceID: fixture.source.id, targets: targets)
                } throws: { ($0 as? ServerError)?.status.code == 409 }
            }
            #expect(try await Self.retained(on: app.db) == [updated.rawBytes])
            try await ClinicalEventStoreTests.expectRows(events: 1, nodes: original.nodes.count, facts: 1, grants: 2, on: app.db)
        }
    }

    @Test
    func repeatedRetractionPreservesFirstEvidenceAndOneLifecycleEffect() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let active = try Self.project(LocalPointEventFixture.bytes(source: fixture.source))
            let first = try Self.project(RetractionEventFixture.bytes(activeBytes: active.rawBytes, sequence: 1))
            let second = try Self.project(RetractionEventFixture.bytes(activeBytes: active.rawBytes, sequence: 2))
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                _ = try await store.accept(active, sourceID: fixture.source.id, targets: fixture.targets(for: active))
                let original = try await store.accept(first, sourceID: fixture.source.id, targets: [])
                let repeated = try await store.accept(second, sourceID: fixture.source.id, targets: [])
                #expect(original.eventID == repeated.eventID)
                #expect(original.payloadSHA256 != repeated.payloadSHA256)
                #expect(try await store.accept(first, sourceID: fixture.source.id, targets: []) == original)
                #expect(try await store.accept(second, sourceID: fixture.source.id, targets: []) == repeated)
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 0)
                let sql = try #require(app.db as? any SQLDatabase)
                let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM clinical_record_retractions").first())
                #expect(try row.decode(column: "count", as: Int.self) == 1)
                let retained = try #require(try await sql.raw("SELECT raw_bytes FROM clinical_events WHERE id = \(bind: original.eventID)").first())
                #expect(try retained.decode(column: "raw_bytes", as: Data.self) == first.rawBytes)
            }
            #expect(try await Self.retained(on: app.db) == [second.rawBytes])
            try await ClinicalEventStoreTests.expectRows(events: 2, nodes: active.nodes.count + first.nodes.count, facts: 1, grants: 2, on: app.db)
        }
    }
}


extension ClinicalRecordRepresentationTests {
    private static func lookup(_ receipt: ClinicalEventReceipt, targets: [ClinicalEventTarget]) throws -> ClinicalEventReceiptStore.Lookup {
        try .init(
            system: receipt.producerEventIdentifier.system,
            value: receipt.producerEventIdentifier.value,
            digest: receipt.payloadSHA256,
            targets: targets
        )
    }

    private static func project(_ bytes: Data) throws -> ValidatedExchangeEvent {
        try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "local-graph-test")
    }

    private static func retained(on database: any Database) async throws -> [Data] {
        let sql = try #require(database as? any SQLDatabase)
        return try await sql.raw("SELECT raw_bytes FROM clinical_event_representations").all().map {
            try $0.decode(column: "raw_bytes", as: Data.self)
        }
    }
}
