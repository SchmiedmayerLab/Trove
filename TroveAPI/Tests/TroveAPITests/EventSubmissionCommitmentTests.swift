//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPITypes


struct EventSubmissionCommitmentTests {
    @Test
    func exactBytesAndNormalizedTargetsBindReceiptRecovery() throws {
        let payload = try Self.payload()
        let commitment = try Self.commitment(bytes: payload.bytes)
        try commitment.verify(Self.receipt(commitment))
        let lookup = commitment.receiptLookup
        #expect(lookup.producerEventIdentifier.system == commitment.producerEventIdentifier.system)
        #expect(lookup.producerEventIdentifier.value == commitment.producerEventIdentifier.value)
        #expect(lookup.payloadSHA256 == commitment.payloadSHA256)
        #expect(lookup.targets.map(\.outputFullUrls) == [["urn:output:a", "urn:output:b"]])
        let reversed = try EventSubmissionCommitment(
            sourceID: DeliveryFixture.sourceID,
            originalBytes: payload.bytes,
            targets: [.init(consentID: DeliveryFixture.consentID, outputFullURLs: ["urn:output:a", "urn:output:b"])]
        )
        #expect(reversed.targetIntent.sha256 == commitment.targetIntent.sha256)
        let changedRecord = try Self.commitment(bytes: Self.payload(seed: "another-version").bytes)
        #expect(changedRecord.payloadSHA256 != commitment.payloadSHA256)
        #expect(throws: EventSubmissionCommitment.ValidationError.receiptMismatch) {
            try changedRecord.verify(Self.receipt(commitment))
        }
    }

    @Test(arguments: ["record", "source", "version-system", "version-value", "bytes", "targets", "count", "time"])
    func everyReceiptCommitmentIsRequired(field: String) throws {
        let commitment = try Self.commitment()
        var receipt = Self.receipt(commitment)
        switch field {
        case "record": receipt.eventId = "invalid"
        case "source": receipt.sourceId = UUID().uuidString
        case "version-system": receipt.producerEventIdentifier.system += "/other"
        case "version-value": receipt.producerEventIdentifier.value += "0"
        case "bytes": receipt.payloadSHA256 = String(repeating: "0", count: 64)
        case "targets": receipt.targetIntentSHA256 = String(repeating: "0", count: 64)
        case "count": receipt.nodeCount += 1
        case "time": receipt.receivedAt = Date(timeIntervalSinceReferenceDate: .infinity)
        default: Issue.record("Unknown receipt field")
        }
        #expect(throws: EventSubmissionCommitment.ValidationError.receiptMismatch) { try commitment.verify(receipt) }
    }

    @Test
    func stagingRequiresCanonicalRecordBytes() throws {
        let bytes = try Self.payload().bytes + Data(" ".utf8)
        #expect(throws: EventSubmissionCommitment.ValidationError.invalidEnvelope) { try Self.commitment(bytes: bytes) }
    }

    @Test(arguments: [Data(), Data("{}".utf8), Data(repeating: 32, count: EventSubmissionLimits.maximumEventBytes + 1)])
    func incompleteOrOversizedEnvelopeCannotBeStaged(bytes: Data) throws {
        #expect(throws: EventSubmissionCommitment.ValidationError.invalidEnvelope) { try Self.commitment(bytes: bytes) }
    }

    @Test
    func recordVersionDoesNotReplaceTheSourceReceiptBinding() throws {
        let bytes = try Self.payload().bytes
        let original = try Self.commitment(bytes: bytes)
        let other = try EventSubmissionCommitment(sourceID: UUID(), originalBytes: bytes, targets: Self.targets())
        #expect(other.producerEventIdentifier == original.producerEventIdentifier)
        #expect(throws: EventSubmissionCommitment.ValidationError.receiptMismatch) { try other.verify(Self.receipt(original)) }
    }

    @Test(arguments: [0, 513])
    func nodeCountIsBoundedBeforeStaging(count: Int) throws {
        let entries = Array(repeating: "{}", count: count).joined(separator: ",")
        let bytes = Data("{\"entry\":[\(entries)]}".utf8)
        #expect(throws: EventSubmissionCommitment.ValidationError.invalidEnvelope) { try Self.commitment(bytes: bytes) }
    }

    @Test
    func recordVersionCannotBeReplacedByAnEventSequence() throws {
        let commitment = try Self.commitment()
        let bytes = try Self.payload().bytes
        let malformed = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(
            of: commitment.producerEventIdentifier.value, with: "e0:30508c4b-fc32-4f76-8028-c09b27a2cb11:42"
        ).utf8)
        #expect(throws: EventSubmissionCommitment.ValidationError.invalidEnvelope) { try Self.commitment(bytes: malformed) }
    }
}


extension EventSubmissionCommitmentTests {
    private static func payload(seed: String = "record") throws -> (bytes: Data, outputs: [String]) {
        let record = try RecordFixture.make(sourceID: DeliveryFixture.sourceID, registrationID: DeliveryFixture.epoch, seed: seed)
        return (record.json, record.outputFullURLs)
    }

    private static func targets() -> [EventTargetIntent.Target] {
        [.init(consentID: DeliveryFixture.consentID, outputFullURLs: ["urn:output:b", "urn:output:a"])]
    }

    private static func commitment(bytes: Data? = nil) throws -> EventSubmissionCommitment {
        try .init(sourceID: DeliveryFixture.sourceID, originalBytes: bytes ?? payload().bytes, targets: targets())
    }

    private static func receipt(_ commitment: EventSubmissionCommitment) -> Components.Schemas.EventReceipt {
        .init(
            eventId: "fd9f41b3-0e17-4362-9f10-a734ca10b58a",
            sourceId: commitment.sourceID.uuidString,
            producerEventIdentifier: commitment.producerEventIdentifier,
            payloadSHA256: commitment.payloadSHA256,
            targetIntentSHA256: commitment.targetIntent.sha256,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            nodeCount: commitment.nodeCount
        )
    }
}
