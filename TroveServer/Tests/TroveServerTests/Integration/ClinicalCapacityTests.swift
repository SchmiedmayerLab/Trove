//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import GroveFHIRContract
import OpenAPIRuntime
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


/// Exercises complete-record custody with a synthetic validation reply; not official IG validation evidence.
struct ClinicalCapacityTests {
    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["TROVE_TEST_VALIDATOR_ASSETS"] != nil,
        "Requires the isolated 16 MiB validator worker and pinned full-validation assets"
    ))
    func largerRecordPassesPinnedValidationWithRecomputedContentIdentity() async throws {
        let capacity = try CollectionCapacityConfiguration(environment: [
            "COLLECTION_MAX_RECORD_BYTES": "6291456", "COLLECTION_MAX_BUNDLE_BYTES": "6292480",
            "COLLECTION_MAX_ENVELOPE_BYTES": "9437184"
        ])
        try await TestApp.withApp(token: .participant(subject: "test-participant"), collectionCapacity: capacity) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let bytes = try Self.fullyKeyedLargeRecord(source: fixture.source)
            let submission = try ClinicalEventBatchTests.submission(bytes, fixture: fixture)
            #expect(bytes.count > 4 * 1024 * 1024)
            try await app.test(.POST, "\(apiBasePath)/participant/sources/\(fixture.source.id)/events", beforeRequest: { request in
                request.bearerAuth(token)
                request.sourceInstallation(fixture.installationID)
                try request.encodeJSONBody(submission)
            }) { response in
                try #require(response.status == .ok)
                let receipt = try response.content.decode(Components.Schemas.EventReceipt.self)
                #expect(receipt.payloadSHA256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            }
        }
    }

    @Test(arguments: [false, true])
    func configuredEnvelopeAndRecordBudgetsReachTheHTTPAdmissionPath(expanded: Bool) async throws {
        let capacity = try CollectionCapacityConfiguration(environment: expanded ? [
            "COLLECTION_MAX_RECORD_BYTES": "6291456", "COLLECTION_MAX_BUNDLE_BYTES": "6292480",
            "COLLECTION_MAX_ENVELOPE_BYTES": "9437184"
        ] : [:])
        try await TestApp.withApp(
            token: .participant(subject: "test-participant"),
            validator: ClinicalEventBatchTests.validator(),
            collectionCapacity: capacity
        ) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let bytes = try Self.largeRecord(LocalPointEventFixture.bytes(source: fixture.source))
            let submission = try ClinicalEventBatchTests.submission(bytes, fixture: fixture)
            let envelope = try JSONEncoder().encode(submission)
            #expect(envelope.count > 6 * 1024 * 1024 && envelope.count < 9 * 1024 * 1024)
            try await app.test(.POST, "\(apiBasePath)/participant/sources/\(fixture.source.id)/events", beforeRequest: { request in
                request.bearerAuth(token)
                request.sourceInstallation(fixture.installationID)
                try request.encodeJSONBody(submission)
            }) { response in
                #expect(response.status == (expanded ? .ok : .payloadTooLarge))
                if expanded {
                    let receipt = try response.content.decode(Components.Schemas.EventReceipt.self)
                    #expect(receipt.payloadSHA256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
                }
            }
            if !expanded { try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db) }
        }
    }

    @Test
    func largerCompleteRecordRequiresExplicitAdmissionBudgetAndRemainsReadable() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let bytes = try Self.largeRecord(LocalPointEventFixture.bytes(source: fixture.source))
            #expect(bytes.count > 4 * 1024 * 1024 && bytes.count < 6 * 1024 * 1024)
            let projected = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "synthetic-test")
            let targets = fixture.targets(for: projected)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let standard = TestApp.clinicalService(database: app.db, validator: ClinicalEventBatchTests.validator())
                await #expect {
                    try await standard.accept(
                        body: HTTPBody(bytes), sourceID: fixture.source.id, targets: targets, installation: fixture.installation
                    )
                } throws: { ($0 as? TroveServer.ServerError)?.status.code == 413 }
                try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
                let limits = try EventSubmissionLimits.Configuration(
                    recordBytes: 6 * 1024 * 1024, bundleBytes: 6 * 1024 * 1024 + 1024, envelopeBytes: 9 * 1024 * 1024
                )
                let expanded = ClinicalEventService(
                    database: app.db, validator: standard.validator, recordings: standard.recordings, limits: limits
                )
                let receipt = try await expanded.accept(
                    body: HTTPBody(bytes), sourceID: fixture.source.id, targets: targets, installation: fixture.installation
                )
                #expect(receipt.payloadSHA256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
                try await ClinicalEventStoreTests.expectRows(events: 1, nodes: receipt.nodeCount, facts: 1, grants: 2, on: app.db)
                let retained = try StudyDataExportStore.validateRetainedRecord(
                    bytes: bytes, digest: receipt.payloadSHA256, validator: "retained-validation-identity"
                )
                #expect(retained.rawBytes == bytes)
            }
        }
    }
}


extension ClinicalCapacityTests {
    private static func fullyKeyedLargeRecord(source: SourceBinding) throws -> Data {
        let originalURL = try #require(Bundle.module.url(forResource: "ImmutablePointEvent", withExtension: "json"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("large-record-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtureURL = directory.appendingPathComponent("record.json")
        try largeRecord(Data(contentsOf: originalURL)).write(to: fixtureURL)
        let instant = Date()
        let small = try ExchangeRecord(validating: ImmutablePointEventFixture.bytes(source: source, effectiveAt: instant))
        // The pinned identity implementation recalculates content-addressed keys after adding the notes.
        let large = try ExchangeRecord(validating: ImmutablePointEventFixture.bytes(source: source, effectiveAt: instant, fixtureURL: fixtureURL))
        #expect(small.sourceRecord == large.sourceRecord)
        #expect(small.version.identifier != large.version.identifier)
        return large.json
    }

    private static func largeRecord(_ bytes: Data) throws -> Data {
        var document = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var entries = try #require(document["entry"] as? [[String: Any]])
        let index = try #require(entries.firstIndex { ($0["resource"] as? [String: Any])?["resourceType"] as? String == "Observation" })
        var resource = try #require(entries[index]["resource"] as? [String: Any])
        // Each FHIR string remains below its own primitive bound; the complete record exceeds 4 MiB.
        resource["note"] = (0..<6).map { _ in ["text": String(repeating: "x", count: 900_000)] }
        entries[index]["resource"] = resource
        document["entry"] = entries
        return try ExchangeRecord(validating: JSONSerialization.data(withJSONObject: document)).json
    }
}
