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
import TroveAPIClient


enum FixtureError: Error {
    case invalid
}


protocol FixtureDeliveryContract: DeliveryContract
where Target == String, SourceBinding == FixtureSource, Receipt == String, Commitment == FixtureCommitment {}

/// Deliberately not Trove's event, binding or receipt format. No HTTP client or study models.
enum JournalFixture: FixtureDeliveryContract {
    static let identifier = "fixture.delivery.v1"
}

enum OtherJournalFixture: FixtureDeliveryContract {
    static let identifier = "fixture.other-delivery.v1"
}

struct FixtureSource: Codable, Equatable, Sendable {
    let id: UUID
    let registrationID: UUID
}

struct FixtureEvent: Codable {
    let sourceID: UUID
    let sequence: Int64
}

struct FixtureCommitment: Sendable {
    let metadata: DeliveryCommitment
    let targetBytes: Data
}


extension FixtureDeliveryContract {
    static var scope: DeliveryScope {
        .init(backend: "https://delivery.example", issuer: "https://account.example", subject: "fixture")
    }

    static func commitment(sourceID: UUID, originalBytes: Data, targets: [String]) throws -> FixtureCommitment {
        let event = try JSONDecoder().decode(FixtureEvent.self, from: originalBytes)
        guard event.sourceID == sourceID, event.sequence > 0, !targets.isEmpty else { throw FixtureError.invalid }
        let targetBytes = try JSONEncoder().encode(targets.sorted())
        return FixtureCommitment(
            metadata: .init(
                sourceID: sourceID,
                eventSystem: "urn:example:events",
                eventValue: eventValue(sourceID: sourceID, sequence: event.sequence),
                payloadSHA256: digest(originalBytes),
                targetSHA256: digest(targetBytes),
                nodeCount: 1
            ),
            targetBytes: targetBytes
        )
    }

    static func metadata(for commitment: FixtureCommitment) -> DeliveryCommitment {
        commitment.metadata
    }

    static func serializedTargets(for commitment: FixtureCommitment) -> Data {
        commitment.targetBytes
    }

    static func eventValue(sourceID: UUID, sequence: Int64) -> String {
        "record:\(sourceID.uuidString):\(sequence)"
    }

    static func acknowledgement(_ commitment: DeliveryCommitment) -> String {
        [
            commitment.sourceID.uuidString, commitment.eventSystem, commitment.eventValue,
            commitment.payloadSHA256, commitment.targetSHA256, String(commitment.nodeCount)
        ].joined(separator: "|")
    }

    static func verify(_ receipt: String, against commitment: DeliveryCommitment) throws {
        guard receipt == acknowledgement(commitment) else { throw FixtureError.invalid }
    }

    static func source(_ binding: FixtureSource, localID: UUID, scope: DeliveryScope) throws -> DeliverySource {
        guard binding.registrationID == localID, scope == Self.scope else { throw FixtureError.invalid }
        return try DeliverySource(
            id: binding.id,
            eventSystem: "urn:example:events",
            revokedAt: nil,
            systems: .derived(root: "urn:example:fixture", keyID: localID.uuidString.lowercased(), epoch: EventSequence(1))
        )
    }

    static func validateUpdate(from existing: FixtureSource, to replacement: FixtureSource) throws {
        guard existing == replacement else { throw FixtureError.invalid }
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
