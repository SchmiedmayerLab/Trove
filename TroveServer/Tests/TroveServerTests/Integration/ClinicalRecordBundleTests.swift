//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import SQLKit
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


struct ClinicalRecordBundleTests {
    @Test(arguments: ["base64", "graph", "size"])
    func invalidTransportCannotAdmitAnyRecord(change: String) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let event = try ClinicalEventBatchTests.submission(LocalPointEventFixture.bytes(source: fixture.source), fixture: fixture)
            var request = try Self.bundle([event], sourceID: fixture.source.id)
            let expected: Int
            switch change {
            case "base64":
                request.bundleBase64 = "e30"
                expected = 400
            case "graph":
                request.bundleBase64 = Data("{}".utf8).base64EncodedString()
                expected = 422
            default:
                request.bundleBase64 = Data(repeating: 32, count: EventSubmissionLimits.maximumBundleBytes + 1).base64EncodedString()
                expected = 413
            }
            await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                await #expect {
                    try await ClinicalEventService(database: app.db, validator: ClinicalEventBatchTests.validator())
                        .acceptBundle(request, sourceID: fixture.source.id)
                } throws: { ($0 as? ServerError)?.status.code == expected }
            }
            try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
        }
    }

    @Test
    func rejectedSiblingDoesNotPreventCustodyAndRegroupedReplay() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let events = try (1...3).map {
                try ClinicalEventBatchTests.submission(
                    LocalPointEventFixture.bytes(source: fixture.source, sequence: UInt64($0), recordID: "sample-\($0)"), fixture: fixture
                )
            }
            var submitted = events
            submitted[1].targets[0].consentId = UUID().uuidString
            let request = try Self.bundle(submitted, sourceID: fixture.source.id)
            let outcomes = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await ClinicalEventService(database: app.db, validator: ClinicalEventBatchTests.validator())
                    .acceptBundle(request, sourceID: fixture.source.id)
            }
            try #require(outcomes.count == 3)
            guard case .EventReceipt(let first) = outcomes[0], case .EventReceipt = outcomes[2] else {
                Issue.record("Valid sibling records were not admitted")
                return
            }
            #expect(outcomes[1].problemStatus == 404)
            try await ClinicalEventStoreTests.expectRows(events: 2, nodes: 2 * first.nodeCount, facts: 2, grants: 4, on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            let retained = try await sql.raw("SELECT raw_bytes FROM clinical_events").all()
            #expect(try Set(retained.map { try $0.decode(column: "raw_bytes", as: Data.self) }) == Set([events[0], events[2]].compactMap {
                Data(base64Encoded: $0.eventBase64)
            }))
            try await TestDatabase.withRestartedApplication(app) { reopened in
                try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                    let regrouped = try Self.bundle([events[2], events[0]], sourceID: fixture.source.id, packedAt: Date().addingTimeInterval(100))
                    let replay = try await ClinicalEventService(database: reopened.db, validator: ClinicalEventBatchTests.validator())
                        .acceptBundle(regrouped, sourceID: fixture.source.id)
                    #expect(replay == [outcomes[2], outcomes[0]])
                }
            }
        }
    }

    @Test(arguments: ["duplicate", "missing", "unknown"])
    func invalidInventoryCannotAdmitAPrefix(change: String) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let events = try (1...2).map {
                try ClinicalEventBatchTests.submission(
                    LocalPointEventFixture.bytes(source: fixture.source, sequence: UInt64($0), recordID: "sample-\($0)"), fixture: fixture
                )
            }
            var request = try Self.bundle(events, sourceID: fixture.source.id)
            switch change {
            case "duplicate": request.records[1] = request.records[0]
            case "missing": request.records.removeLast()
            default: request.records[1].commitment.producerEventIdentifier.value = "unknown"
            }
            await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                await #expect {
                    try await ClinicalEventService(database: app.db, validator: ClinicalEventBatchTests.validator())
                        .acceptBundle(request, sourceID: fixture.source.id)
                } throws: { ($0 as? ServerError)?.status.code == 400 }
            }
            try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
        }
    }

    @Test(arguments: [false, true])
    func invalidRecordCommitmentDoesNotAdmitItsBytesOrRejectASibling(changeDigest: Bool) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let events = try (1...2).map {
                try ClinicalEventBatchTests.submission(
                    LocalPointEventFixture.bytes(source: fixture.source, sequence: UInt64($0), recordID: "sample-\($0)"), fixture: fixture
                )
            }
            var request = try Self.bundle(events, sourceID: fixture.source.id)
            if changeDigest {
                request.records[0].commitment.payloadSHA256 = String(repeating: "0", count: 64)
            } else {
                request.records[0].entryFullUrls.removeFirst()
            }
            let results = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await ClinicalEventService(database: app.db, validator: ClinicalEventBatchTests.validator())
                    .acceptBundle(request, sourceID: fixture.source.id)
            }
            #expect(results[0].problemStatus == 400)
            guard case .EventReceipt(let receipt) = results[1] else {
                Issue.record("Valid sibling was not admitted")
                return
            }
            try await ClinicalEventStoreTests.expectRows(events: 1, nodes: receipt.nodeCount, facts: 1, grants: 2, on: app.db)
        }
    }
}


extension ClinicalRecordBundleTests {
    static func bundle(
        _ events: [Components.Schemas.EventSubmission], sourceID: UUID, packedAt: Date = Date()
    ) throws -> Components.Schemas.RecordBundleSubmission {
        let records = try events.map { try ExchangeRecord(validating: #require(Data(base64Encoded: $0.eventBase64))) }
        var packer = ExchangeBundlePacker(kind: try #require(records.first).kind)
        let members = try zip(records, events).map { record, event in
            try #require(packer.insert(record) == .inserted)
            let targets = try event.targets.map {
                EventTargetIntent.Target(consentID: try #require(UUID(uuidString: $0.consentId)), outputFullURLs: $0.outputFullUrls)
            }
            let commitment = try EventSubmissionCommitment(sourceID: sourceID, originalBytes: record.json, targets: targets)
            return try Components.Schemas.RecordBundleMember(
                commitment: commitment.receiptLookup, entryFullUrls: ExchangeRecordBytes(record).entryFullURLs
            )
        }
        return try .init(bundleBase64: packer.bundle(packedAt: packedAt).json.base64EncodedString(), records: members)
    }
}
