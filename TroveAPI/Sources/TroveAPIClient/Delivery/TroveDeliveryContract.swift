//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import TroveAPITypes


/// Trove's wire contract for the shared durable journal. Authentication and consent remain in the caller and receiver.
public enum TroveDeliveryContract: DeliveryContract {
    public typealias Target = EventTargetIntent.Target
    public typealias SourceBinding = Components.Schemas.ParticipantSource
    public typealias Receipt = Components.Schemas.EventReceipt
    public typealias Commitment = EventSubmissionCommitment

    public static let identifier = "trove.event-delivery.v2"

    public static func commitment(sourceID: UUID, originalBytes: Data, targets: [Target]) throws -> Commitment {
        try Commitment(sourceID: sourceID, originalBytes: originalBytes, targets: targets)
    }

    public static func metadata(for commitment: Commitment) -> DeliveryCommitment {
        .init(
            sourceID: commitment.sourceID,
            eventSystem: commitment.producerEventIdentifier.system,
            eventValue: commitment.producerEventIdentifier.value,
            payloadSHA256: commitment.payloadSHA256,
            targetSHA256: commitment.targetIntent.sha256,
            nodeCount: commitment.nodeCount
        )
    }

    public static func serializedTargets(for commitment: Commitment) -> Data {
        Data(commitment.targetIntent.serialized.utf8)
    }

    public static func verify(_ receipt: Receipt, against commitment: DeliveryCommitment) throws {
        guard UUID(uuidString: receipt.eventId) != nil, UUID(uuidString: receipt.sourceId) == commitment.sourceID,
              receipt.producerEventIdentifier.system.utf8.elementsEqual(commitment.eventSystem.utf8),
              receipt.producerEventIdentifier.value.utf8.elementsEqual(commitment.eventValue.utf8),
              receipt.payloadSHA256 == commitment.payloadSHA256, receipt.targetIntentSHA256 == commitment.targetSHA256,
              receipt.nodeCount == commitment.nodeCount, receipt.receivedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw Commitment.ValidationError.receiptMismatch
        }
    }

    public static func validateUpdate(from existing: SourceBinding, to replacement: SourceBinding) throws {
        var identity = replacement
        identity.revokedAt = existing.revokedAt
        guard identity == existing,
              existing.revokedAt == nil || replacement.revokedAt == existing.revokedAt else { throw DeliveryJournalError.sourceConflict }
    }

    public static func source(_ binding: Components.Schemas.ParticipantSource, localID: UUID, scope: DeliveryScope) throws -> DeliverySource {
        guard UUID(uuidString: binding.registrationID) == localID,
              let id = UUID(uuidString: binding.id), binding.id == id.uuidString.lowercased(),
              UUID(uuidString: binding.participantIdentifier.value) != nil,
              binding.participantIdentifier.system == scope.issuer + "/trove/participants",
              (1...512).contains(binding.eventIdentifierSystem.utf8.count),
              (0...253_402_300_799).contains(binding.createdAt.timeIntervalSince1970),
              binding.revokedAt.map({ (binding.createdAt.timeIntervalSince1970...253_402_300_799).contains($0.timeIntervalSince1970) }) ?? true else {
            throw DeliveryJournalError.invalidSourceBinding
        }
        do {
            let eventSystem = try IdentifierSystem(binding.eventIdentifierSystem)
            let participantSystem = try IdentifierSystem(binding.participantIdentifier.system)
            let systems = try binding.identifierSystems()
            let reserved = [
                systems.sourceRecord, systems.sourceOutput, systems.writerRecord, systems.providerRecord,
                systems.providerOutput, systems.sourceArtifact, systems.providerArtifact, systems.sourceContext,
                systems.recordingDevice, systems.deviceSnapshot, systems.event, systems.entryNode
            ]
            guard eventSystem == systems.event, !reserved.contains(participantSystem) else {
                throw DeliveryJournalError.invalidSourceBinding
            }
            return DeliverySource(id: id, eventSystem: binding.eventIdentifierSystem, revokedAt: binding.revokedAt, systems: systems)
        } catch {
            throw DeliveryJournalError.invalidSourceBinding
        }
    }
}
