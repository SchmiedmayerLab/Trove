//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import SQLKit


/// Supported producer authority; unknown persisted values must fail decoding.
enum SourceKind: String, Codable, Sendable { case participantApp = "participant-app" }


/// Account-owned producer stream, not evidence of device attestation or provider origin.
struct SourceBinding: Sendable, Equatable {
    let id: UUID
    let participantID: UUID
    let keyID: UUID
    let keyEpoch: KeyEpoch
    let repositoryKind: SourceRepositoryKind
    let kind: SourceKind
    let eventIdentifierSystem: String
    let identifierRoot: String
    let participantIdentifierSystem: String
    let participantIdentifierValue: String
    let createdAt: Date
    let revokedAt: Date?

    init(row: any SQLRow) throws {
        id = try row.decode(column: "id", as: UUID.self)
        participantID = try row.decode(column: "participant_id", as: UUID.self)
        keyID = try row.decode(column: "key_id", as: UUID.self)
        keyEpoch = try KeyEpoch(row.decode(column: "key_epoch", as: String.self))
        repositoryKind = try row.decode(column: "repository_kind", as: SourceRepositoryKind.self)
        kind = try row.decode(column: "kind", as: SourceKind.self)
        eventIdentifierSystem = try row.decode(column: "event_identifier_system", as: String.self)
        identifierRoot = try row.decode(column: "identifier_root", as: String.self)
        guard try SourceIdentityNamespaces.assign(root: identifierRoot, keyID: keyID, epoch: keyEpoch).recordVersion.rawValue
            == eventIdentifierSystem else {
            throw ExchangeIdentityError.invalidIdentifierSystem(eventIdentifierSystem)
        }
        participantIdentifierSystem = try row.decode(column: "participant_identifier_system", as: String.self)
        participantIdentifierValue = try row.decode(column: "participant_identifier_value", as: String.self)
        createdAt = try row.decode(column: "created_at", as: Date.self)
        revokedAt = try row.decode(column: "revoked_at", as: Date?.self)
    }
}
