//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation


/// Identity required before a client can acknowledge durable custody of exact staged bytes.
/// This validates bounded receipt commitments, not FHIR conformance or collection authority.
public struct EventSubmissionCommitment: Sendable {
    private struct Envelope: Decodable {
        struct Entry: Decodable {}
        struct Identifier: Decodable {
            let system: String
            let value: String
        }
        let identifier: Identifier
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
        let identifier = envelope.identifier
        let prefix = "e0:\(sourceID.uuidString.lowercased()):"
        guard (1...512).contains(identifier.system.utf8.count), (1...512).contains(identifier.value.utf8.count),
              identifier.value.hasPrefix(prefix) else { throw ValidationError.invalidEventIdentity }
        let sequence = identifier.value.dropFirst(prefix.count)
        guard let first = sequence.utf8.first, (49...57).contains(first),
              sequence.utf8.allSatisfy({ (48...57).contains($0) }) else { throw ValidationError.invalidEventIdentity }
        self.sourceID = sourceID
        producerEventIdentifier = .init(system: identifier.system, value: identifier.value)
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
