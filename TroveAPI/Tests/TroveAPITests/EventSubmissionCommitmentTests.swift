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
        let commitment = try Self.commitment()
        #expect(commitment.targetIntent.sha256 == "958cdaf170a0a3d22eee96febcf3937309a99d49233294ae065089b127219f13")
        try commitment.verify(Self.receipt(commitment))
        let lookup = commitment.receiptLookup
        #expect(lookup.producerEventIdentifier.system == "https://example.test/events")
        #expect(lookup.producerEventIdentifier.value == "e0:30508c4b-fc32-4f76-8028-c09b27a2cb11:42")
        #expect(lookup.payloadSHA256 == commitment.payloadSHA256)
        #expect(lookup.targets.map(\.outputFullUrls) == [["urn:output:a", "urn:output:b"]])
        let changedBytes = try Self.commitment(bytes: Self.bytes + Data(" ".utf8))
        #expect(changedBytes.producerEventIdentifier == commitment.producerEventIdentifier)
        #expect(changedBytes.payloadSHA256 != commitment.payloadSHA256)
        #expect(throws: EventSubmissionCommitment.ValidationError.receiptMismatch) {
            try changedBytes.verify(Self.receipt(commitment))
        }
    }

    @Test(arguments: ["record", "source", "event-system", "event-value", "bytes", "targets", "count", "time"])
    func everyReceiptCommitmentIsRequired(field: String) throws {
        let commitment = try Self.commitment()
        var receipt = Self.receipt(commitment)
        switch field {
        case "record": receipt.eventId = "invalid"
        case "source": receipt.sourceId = UUID().uuidString
        case "event-system": receipt.producerEventIdentifier.system += "/other"
        case "event-value": receipt.producerEventIdentifier.value += "0"
        case "bytes": receipt.payloadSHA256 = String(repeating: "0", count: 64)
        case "targets": receipt.targetIntentSHA256 = String(repeating: "0", count: 64)
        case "count": receipt.nodeCount += 1
        case "time": receipt.receivedAt = Date(timeIntervalSinceReferenceDate: .infinity)
        default: Issue.record("Unknown receipt field")
        }
        #expect(throws: EventSubmissionCommitment.ValidationError.receiptMismatch) { try commitment.verify(receipt) }
    }

    @Test
    func completeIdentifierComparisonDoesNotFoldUnicode() throws {
        let bytes = Data(String(decoding: Self.bytes, as: UTF8.self).replacingOccurrences(of: "/events", with: "/caf\u{e9}").utf8)
        let commitment = try Self.commitment(bytes: bytes)
        var receipt = Self.receipt(commitment)
        receipt.producerEventIdentifier.system = "https://example.test/cafe\u{301}"
        #expect(receipt.producerEventIdentifier.system == commitment.producerEventIdentifier.system)
        #expect(throws: EventSubmissionCommitment.ValidationError.receiptMismatch) { try commitment.verify(receipt) }
    }

    @Test(arguments: ["0", "01", "-1", "1.0", "1e2", "１", ""])
    func malformedProducerSequenceCannotBeStaged(sequence: String) throws {
        let bytes = Data(String(decoding: Self.bytes, as: UTF8.self).replacingOccurrences(of: ":42\"", with: ":\(sequence)\"").utf8)
        #expect(throws: EventSubmissionCommitment.ValidationError.invalidEventIdentity) { try Self.commitment(bytes: bytes) }
    }

    @Test(arguments: [Data(), Data("{}".utf8), Data(repeating: 32, count: EventSubmissionLimits.maximumEventBytes + 1)])
    func incompleteOrOversizedEnvelopeCannotBeStaged(bytes: Data) throws {
        #expect(throws: EventSubmissionCommitment.ValidationError.invalidEnvelope) { try Self.commitment(bytes: bytes) }
    }

    @Test
    func aDifferentSourceCannotClaimTheStagedEvent() throws {
        #expect(throws: EventSubmissionCommitment.ValidationError.invalidEventIdentity) {
            try EventSubmissionCommitment(sourceID: UUID(), originalBytes: Self.bytes, targets: Self.targets())
        }
    }

    @Test
    func canonicalProducerSequenceDoesNotDependOnMachineIntegerWidth() throws {
        let sequence = String(repeating: "9", count: 100)
        let bytes = Data(String(decoding: Self.bytes, as: UTF8.self).replacingOccurrences(of: ":42\"", with: ":\(sequence)\"").utf8)
        let commitment = try Self.commitment(bytes: bytes)
        #expect(commitment.producerEventIdentifier.value.hasSuffix(":" + sequence))
        try commitment.verify(Self.receipt(commitment))
    }

    @Test(arguments: [0, 513])
    func nodeCountIsBoundedBeforeStaging(count: Int) throws {
        let entries = Array(repeating: "{}", count: count).joined(separator: ",")
        let bytes = Data(String(decoding: Self.bytes, as: UTF8.self).replacingOccurrences(of: "[{},{}]", with: "[\(entries)]").utf8)
        #expect(throws: EventSubmissionCommitment.ValidationError.invalidEnvelope) { try Self.commitment(bytes: bytes) }
    }
}


extension EventSubmissionCommitmentTests {
    // Deliberately only an envelope: receipt verification must not be advertised as FHIR validation.
    private static let bytes = Data(#"""
        {"identifier":{"type":{"text":"Event"},"system":"https://example.test/events",
        "value":"e0:30508c4b-fc32-4f76-8028-c09b27a2cb11:42"},"entry":[{},{}]}
        """#.utf8)

    private static func targets() throws -> [EventTargetIntent.Target] {
        [.init(consentID: try #require(UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")), outputFullURLs: ["urn:output:b", "urn:output:a"])]
    }

    private static func commitment(bytes: Data = Self.bytes) throws -> EventSubmissionCommitment {
        try .init(sourceID: #require(UUID(uuidString: "30508c4b-fc32-4f76-8028-c09b27a2cb11")), originalBytes: bytes, targets: targets())
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
