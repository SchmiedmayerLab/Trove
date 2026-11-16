//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import Testing
@testable import TroveAPIClient
import TroveAPITypes


struct CollectionCapacityTests {
    @Test
    func configurationKeepsSeparateBudgetsAndRejectsUnusableCombinations() throws {
        let defaults = try EventDeliveryCapacityConfiguration()
        #expect(defaults.admission.recordBytes == 4 * 1024 * 1024)
        #expect(defaults.journal.maximumBytes == 64 * 1024 * 1024)
        let configured = try EventDeliveryCapacityConfiguration(settings: [
            "COLLECTION_MAX_RECORD_BYTES": "6291456", "COLLECTION_MAX_BUNDLE_BYTES": "6292480",
            "COLLECTION_MAX_ENVELOPE_BYTES": "9437184", "COLLECTION_MAX_BATCH_RECORDS": "3",
            "COLLECTION_MAX_PENDING_BYTES": "134217728", "COLLECTION_MAX_RECORDING_BYTES": "268435456",
            "COLLECTION_MAX_PENDING_RECORDING_BYTES": "2147483648"
        ])
        #expect(configured.journal.maximumPayloadBytes == configured.admission.recordBytes)
        #expect(configured.journal.maximumBytes == 128 * 1024 * 1024)
        #expect(configured.journal.maximumRecordingBytes == 256 * 1024 * 1024)
        #expect(configured.journal.maximumPendingRecordingBytes == 2 * 1024 * 1024 * 1024)
        #expect(configured.admission.batchRecords == 3)
        #expect(throws: (any Error).self) { try EventDeliveryCapacityConfiguration(settings: ["COLLECTION_MAX_RECORD_BYTES": "6291456"]) }
        #expect(throws: (any Error).self) { try EventDeliveryCapacityConfiguration(settings: ["COLLECTION_MAX_DATABASE_BYTES": "1"]) }
    }

    @Test(arguments: ["", "0", "-1", "+1", " 1", "1.0", "99999999999999999999999"])
    func invalidSettingsNeverSilentlyFallBack(value: String) {
        for key in CollectionCapacitySetting.allCases {
            #expect(throws: (any Error).self) { try key.read(from: [key.rawValue: value], default: 1) }
        }
    }

    @Test
    func wholeRecordAboveFourMiBResumesAfterCapacityIncreaseWithoutAdvancingFailedCursor() async throws {
        let record = try RecordFixture.make(
            sourceID: DeliveryFixture.sourceID,
            registrationID: DeliveryFixture.epoch,
            seed: "large-record",
            note: String(repeating: "x", count: 5 * 1024 * 1024)
        )
        let payload = EventDeliveryJournal.Payload(
            bytes: record.json, targets: [.init(consentID: DeliveryFixture.consentID, outputFullURLs: record.outputFullURLs)]
        )
        let raised = try EventDeliveryCapacityConfiguration(settings: [
            "COLLECTION_MAX_RECORD_BYTES": "6291456", "COLLECTION_MAX_BUNDLE_BYTES": "6292480",
            "COLLECTION_MAX_ENVELOPE_BYTES": "9437184"
        ])
        try await DeliveryFixture.withJournal { journal, url in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            await #expect(throws: DeliveryJournalError.capacityExceeded) {
                try await journal.stage(from: checkpoint, nextCursor: Data([7]), payloads: [payload])
            }
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID).cursor == checkpoint.cursor)
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting, limits: raised.journal)
            do {
                let next = try await reopened.checkpoint(for: DeliveryFixture.sourceID)
                let ids = try await reopened.stage(from: next, nextCursor: Data([7]), payloads: [payload])
                let transport = DeliveryTransport()
                let client = Client(serverURL: try #require(URL(string: DeliveryFixture.scope.backend)), configuration: .trove, transport: transport)
                let bounded = try EventDeliveryDrainer(journal: reopened, scope: DeliveryFixture.scope, client: client, validateSession: {})
                await #expect(throws: DeliveryJournalError.capacityExceeded) { try await bounded.drain() }
                #expect(try await reopened.pendingDeliveryIDs() == ids)
                #expect(try await reopened.status(for: #require(ids.first)) == .pending)
                let expanded = try EventDeliveryDrainer(
                    journal: reopened, scope: DeliveryFixture.scope, client: client, limits: raised.admission, validateSession: {}
                )
                #expect(try await expanded.drain().map(\.status) == [.delivered])
                #expect(await transport.submittedBytes == [record.json])
                #expect(await transport.submittedBundleBytes.count == 1)
                #expect(try await reopened.checkpoint(for: DeliveryFixture.sourceID).cursor == Data([7]))
            } catch {
                await reopened.close()
                throw error
            }
            await reopened.close()
        }
    }
}
