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


/// Identity required before a client can acknowledge durable custody of exact staged bytes.
/// This validates bounded record structure and receipt commitments, not full FHIR conformance or collection authority.
public struct EventSubmissionCommitment: Sendable {
    private struct Envelope: Decodable {
        struct Entry: Decodable {}
        let entry: [Entry]
    }

    public enum ValidationError: Error, Equatable {
        case invalidEnvelope
        case invalidEventIdentity
        case receiptMismatch
    }

    public let sourceID: UUID
    public let producerEventIdentifier: Components.Schemas.EventReceipt.ProducerEventIdentifierPayload
    public let payloadSHA256: String
    public let targetIntent: EventTargetIntent
    public let nodeCount: Int

    public init(sourceID: UUID, originalBytes: Data, targets: [EventTargetIntent.Target]) throws {
        guard !originalBytes.isEmpty, originalBytes.count <= EventSubmissionLimits.maximumEventBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: originalBytes),
              (1...512).contains(envelope.entry.count) else { throw ValidationError.invalidEnvelope }
        guard let record = try? ExchangeRecord(validating: originalBytes), record.json == originalBytes else {
            throw ValidationError.invalidEnvelope
        }
        let identifier = record.version.identifier.identifier
        guard (1...512).contains(identifier.system.rawValue.utf8.count), (1...512).contains(identifier.value.utf8.count) else {
            throw ValidationError.invalidEventIdentity
        }
        self.sourceID = sourceID
        producerEventIdentifier = .init(system: identifier.system.rawValue, value: identifier.value)
        payloadSHA256 = SHA256.hash(data: originalBytes).map { String(format: "%02x", $0) }.joined()
        targetIntent = try EventTargetIntent(targets: targets)
        nodeCount = envelope.entry.count
    }

    /// Reject partial, foreign, altered or malformed acknowledgements; HTTP success alone is insufficient.
    public func verify(_ receipt: Components.Schemas.EventReceipt) throws {
        guard UUID(uuidString: receipt.eventId) != nil, UUID(uuidString: receipt.sourceId) == sourceID,
              receipt.producerEventIdentifier.system.utf8.elementsEqual(producerEventIdentifier.system.utf8),
              receipt.producerEventIdentifier.value.utf8.elementsEqual(producerEventIdentifier.value.utf8),
              receipt.payloadSHA256 == payloadSHA256, receipt.targetIntentSHA256 == targetIntent.sha256,
              receipt.nodeCount == nodeCount, receipt.receivedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ValidationError.receiptMismatch
        }
    }
}


extension EventSubmissionCommitment {
    /// Uses the original commitment after an uncertain response, including source revocation.
    public var receiptLookup: Components.Schemas.EventReceiptLookup {
        .init(
            producerEventIdentifier: .init(system: producerEventIdentifier.system, value: producerEventIdentifier.value),
            payloadSHA256: payloadSHA256,
            targets: targetIntent.targets.map { .init(consentId: $0.consentID.uuidString.lowercased(), outputFullUrls: $0.outputFullURLs) }
        )
    }
}
