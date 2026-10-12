//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract


public enum DeliveryJournalError: Error, Equatable {
    case invalidConfiguration
    case unsafeStorage
    case wrongScope
    case corruptJournal
    case unsupportedFormat
    case sourceConflict
    case unknownSource
    case sourceRevoked
    case invalidSourceBinding
    case staleCheckpoint
    case capacityExceeded
    case sequenceExhausted
    case eventIdentityMismatch
    case unknownDelivery
    case receiptConflict
}


/// Exact account and backend identity; string comparisons preserve UTF-8 bytes.
public struct DeliveryScope: Codable, Sendable, Equatable {
    public let backend: String
    public let issuer: String
    public let subject: String

    public init(backend: String, issuer: String, subject: String) {
        self.backend = backend
        self.issuer = issuer
        self.subject = subject
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.backend.utf8.elementsEqual(rhs.backend.utf8)
            && lhs.issuer.utf8.elementsEqual(rhs.issuer.utf8)
            && lhs.subject.utf8.elementsEqual(rhs.subject.utf8)
    }
}


/// Immutable commitments retained after the payload has been retired.
public struct DeliveryCommitment: Sendable, Equatable {
    public let sourceID: UUID
    public let eventSystem: String
    public let eventValue: String
    public let payloadSHA256: String
    public let targetSHA256: String
    public let nodeCount: Int

    public init(sourceID: UUID, eventSystem: String, eventValue: String, payloadSHA256: String, targetSHA256: String, nodeCount: Int) {
        self.sourceID = sourceID
        self.eventSystem = eventSystem
        self.eventValue = eventValue
        self.payloadSHA256 = payloadSHA256
        self.targetSHA256 = targetSHA256
        self.nodeCount = nodeCount
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sourceID == rhs.sourceID && lhs.eventSystem.utf8.elementsEqual(rhs.eventSystem.utf8)
            && lhs.eventValue.utf8.elementsEqual(rhs.eventValue.utf8)
            && lhs.payloadSHA256 == rhs.payloadSHA256 && lhs.targetSHA256 == rhs.targetSHA256 && lhs.nodeCount == rhs.nodeCount
    }
}


/// Validated source identity, independent of a backend's response model.
public struct DeliverySource: Sendable {
    public let id: UUID
    public let eventSystem: String
    public let revokedAt: Date?
    public let systems: DeploymentIdentifierSystems

    public init(id: UUID, eventSystem: String, revokedAt: Date?, systems: DeploymentIdentifierSystems) {
        self.id = id
        self.eventSystem = eventSystem
        self.revokedAt = revokedAt
        self.systems = systems
    }
}


/// Application-owned wire semantics. Implementations must be deterministic and side-effect-free.
/// The journal owns transactions and durability, not authentication, consent, FHIR validation or HTTP.
/// Change the identifier whenever persisted bindings, targets or receipts become incompatible.
public protocol DeliveryContract: Sendable {
    associatedtype Target: Codable, Sendable
    associatedtype SourceBinding: Codable, Equatable, Sendable
    associatedtype Receipt: Codable, Equatable, Sendable
    associatedtype Commitment: Sendable

    static var identifier: String { get }
    static func commitment(sourceID: UUID, originalBytes: Data, targets: [Target]) throws -> Commitment
    static func metadata(for commitment: Commitment) -> DeliveryCommitment
    /// The canonical encoding must decode back into [Target].
    static func serializedTargets(for commitment: Commitment) -> Data
    /// Reject every mismatch, including receipt identity and timestamps, before payload retirement.
    static func verify(_ receipt: Receipt, against commitment: DeliveryCommitment) throws
    /// Validate the entire binding, including its registration nonce and account scope.
    static func source(_ binding: SourceBinding, localID: UUID, scope: DeliveryScope) throws -> DeliverySource
    /// Permit only identity-preserving updates and irreversible revocation.
    static func validateUpdate(from existing: SourceBinding, to replacement: SourceBinding) throws
}
