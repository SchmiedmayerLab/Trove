//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveSensorKitFHIR
import Testing
@testable import TroveSensorKit


struct SensorKitBatchReceiptTests {
    private static let identity = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

    @Test
    func roundTripRetainsFirstFactsAndStagedState() throws {
        let first = try batch()
        var receipt = try SensorKitBatchReceipt(batch: first)
        receipt.phase = .staged
        let restored = try SensorKitBatchReceipt(encoded: receipt.encoded())
        #expect(restored.phase == .staged)
        #expect(restored.facts == receipt.facts)
        let retry = try batch(instant: first.facts.conversionInstant.addingTimeInterval(3600))
        try restored.verify(SensorKitBatchReceipt(batch: retry))
        let facts = try SensorKitBatchSnapshot(encoded: restored.facts, maximumByteCount: SensorKitBatchReceipt.maximumFactsBytes)
        #expect(facts.conversionInstant == first.facts.conversionInstant)
    }

    @Test(arguments: ["coordinate", "digest", "identity", "partition"])
    func changedRetryCannotReuseIdentity(field: String) throws {
        let original = try SensorKitBatchReceipt(batch: batch())
        let changed = try batch(
            coordinate: field == "coordinate" ? "batch-two" : "batch-one",
            identity: field == "identity" ? UUID() : Self.identity,
            digest: Data(repeating: field == "digest" ? 2 : 1, count: 32),
            partition: field == "partition" ? "Watch2,1" : "Watch1,1"
        )
        #expect(throws: SensorKitAcquisition.AcquisitionError.retryMismatch) {
            try original.verify(SensorKitBatchReceipt(batch: changed))
        }
    }

    @Test
    func corruptOrFutureReceiptNeverResetsState() throws {
        let receipt = try SensorKitBatchReceipt(batch: batch())
        let bytes = try receipt.encoded()
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["version"] = 3
        let future = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: SensorKitAcquisition.AcquisitionError.invalidBatch) { try SensorKitBatchReceipt(encoded: future) }
        #expect(throws: SensorKitAcquisition.AcquisitionError.invalidBatch) {
            try SensorKitBatchReceipt(encoded: Data(repeating: 0, count: 65_537))
        }
        #expect(try SensorKitBatchReceipt(encoded: bytes).facts == receipt.facts)
    }

    @Test
    func sourceCatalogAndPartitionAreValidated() throws {
        let entry = try #require(SensorKitCatalog.current.entries.first { $0.structuredContract == .onWrist })
        let query = try SensorKitQueryDefinition(sourceToken: entry.sourceToken, deviceProductType: "Watch1,1")
        #expect(try SensorKitQueryDefinition(encoded: query.encoded()) == query)
        #expect(throws: SensorKitAcquisition.AcquisitionError.invalidBatch) {
            try SensorKitQueryDefinition(sourceToken: "unknown", deviceProductType: "Watch1,1")
        }
        #expect(throws: SensorKitAcquisition.AcquisitionError.invalidBatch) {
            try SensorKitQueryDefinition(sourceToken: entry.sourceToken, deviceProductType: "")
        }
    }

    private func batch(
        coordinate: String = "batch-one",
        identity: UUID = Self.identity,
        digest: Data = Data(repeating: 1, count: 32),
        partition: String = "Watch1,1",
        instant: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) throws -> SensorKitAcquisition.Batch {
        let sourceID = SensorKitSourceRecordID(identity)
        let source = try #require(SensorKitCatalog.current.entries.first { $0.structuredContract == .onWrist })
        return try .init(
            coordinate: coordinate,
            sourceToken: source.sourceToken,
            deviceProductType: partition,
            inputs: [
                .init(
                    sourceID: sourceID,
                    sourceToken: source.sourceToken,
                    profile: .onWrist,
                    record: .onWrist(.init(
                        sourceRecordID: sourceID,
                        timestamp: instant,
                        onWrist: true,
                        currentStateStart: instant,
                        wristLocation: .left,
                        crownOrientation: .right
                    )),
                    digest: digest,
                    start: instant,
                    end: nil
                )
            ],
            facts: SensorKitBatchSnapshot(
                application: ApplicationDevice(name: "Test", bundleIdentifier: "org.example.test", version: "1", build: "1"),
                host: HostDevice(operatingSystemName: "iOS", operatingSystemVersion: "27.2"),
                recordingDevice: nil,
                sourceTimeZone: #require(TimeZone(secondsFromGMT: 0)),
                conversionInstant: instant
            ),
            acknowledge: {}
        )
    }
}
