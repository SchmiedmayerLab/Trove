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


struct EventDeliveryRepresentationTests {
    @Test
    func sameVersionRepresentationsKeepIndependentBytesAndReceiptsAcrossRestart() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let original = try DeliveryFixture.payload(sequence: 1, changes: ["sample"])
            let entries = try ExchangeRecordBytes(ExchangeRecord(validating: original.bytes))
            let variant = try EventDeliveryJournal.Payload(
                bytes: entries.restoring(entryFullURLs: entries.entryFullURLs.reversed()).json, targets: original.targets
            )
            try #require(variant.bytes != original.bytes)
            let nextVersion = try DeliveryFixture.payload(sequence: 2, changes: ["sample"])
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let ids = try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: [original, variant, original, nextVersion])
            try #require(ids.count == 4)
            #expect(ids[0] == ids[2])
            #expect(Set(ids).count == 3)
            #expect(try await journal.pendingDeliveryIDs() == [ids[0], ids[1], ids[3]])
            let first = try #require(await journal.prepareAttempt(ids[0]))
            let receipt = DeliveryFixture.receipt(first)
            try await journal.recordReceipt(receipt, for: ids[0])
            await #expect(throws: EventSubmissionCommitment.ValidationError.receiptMismatch) {
                try await journal.recordReceipt(receipt, for: ids[1])
            }
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let second = try #require(await reopened.prepareAttempt(ids[1]))
            #expect(second.bytes == variant.bytes)
            #expect(second.commitment.producerEventIdentifier == first.commitment.producerEventIdentifier)
            #expect(second.commitment.payloadSHA256 != first.commitment.payloadSHA256)
            try await reopened.recordReceipt(DeliveryFixture.receipt(second), for: ids[1])
            #expect(try await reopened.pendingDeliveryIDs() == [ids[3]])
            await reopened.close()
        }
    }
}
