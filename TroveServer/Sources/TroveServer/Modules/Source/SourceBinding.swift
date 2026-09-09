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
    let registrationID: UUID
    let kind: SourceKind
    let eventIdentifierSystem: String
    let pseudonymousIdentifierSystems: PseudonymousIdentitySystems
    let participantIdentifierSystem: String
    let participantIdentifierValue: String
    let createdAt: Date
    let revokedAt: Date?

    var producerInstance: UUID { id }

    init(row: any SQLRow) throws {
        id = try row.decode(column: "id", as: UUID.self)
        participantID = try row.decode(column: "participant_id", as: UUID.self)
        registrationID = try row.decode(column: "registration_id", as: UUID.self)
        kind = try row.decode(column: "kind", as: SourceKind.self)
        eventIdentifierSystem = try row.decode(column: "event_identifier_system", as: String.self)
        pseudonymousIdentifierSystems = try SourceIdentityNamespaces.assign(eventSystem: eventIdentifierSystem)
        participantIdentifierSystem = try row.decode(column: "participant_identifier_system", as: String.self)
        participantIdentifierValue = try row.decode(column: "participant_identifier_value", as: String.self)
        createdAt = try row.decode(column: "created_at", as: Date.self)
        revokedAt = try row.decode(column: "revoked_at", as: Date?.self)
    }
}
