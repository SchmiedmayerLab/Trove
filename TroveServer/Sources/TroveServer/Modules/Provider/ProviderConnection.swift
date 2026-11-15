//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SQLKit


struct ProviderConnection: Sendable {
    enum Status: String, Codable, Sendable { case active, disconnected, reauthorizationRequired = "reauthorization-required" }
    enum RefreshState: String, Sendable { case ready, dispatched, uncertain }

    let id: UUID
    let participantID: UUID
    let registrationID: UUID
    let sourceID: UUID
    let accountPseudonym: UUID
    let generation: Int64
    let credentialVersion: Int64
    let credentialEnvelope: ProviderCredentialVault.Envelope?
    let accountEnvelope: ProviderCredentialVault.Envelope
    let status: Status
    let refreshState: RefreshState
    let refreshID: UUID?
    let lastAttempt: Date?
    let lastSuccessfulFetch: Date?
    let nextAttempt: Date
    let dormantUntil: Date

    var credentialContext: ProviderCredentialVault.Context {
        .init(
            participantID: participantID, registrationID: registrationID, recordID: id,
            version: credentialVersion, purpose: .participantCredential
        )
    }

    var accountContext: ProviderCredentialVault.Context {
        .init(participantID: participantID, registrationID: registrationID, recordID: id, version: 1, purpose: .accountIdentity)
    }

    init(row: any SQLRow) throws {
        id = try row.decode(column: "id", as: UUID.self)
        participantID = try row.decode(column: "participant_id", as: UUID.self)
        registrationID = try row.decode(column: "registration_id", as: UUID.self)
        sourceID = try row.decode(column: "source_id", as: UUID.self)
        accountPseudonym = try row.decode(column: "account_pseudonym", as: UUID.self)
        generation = try row.decode(column: "generation", as: Int64.self)
        credentialVersion = try row.decode(column: "credential_version", as: Int64.self)
        credentialEnvelope = try row.decode(column: "credential_envelope", as: String?.self).map {
            try ProviderSQL.decode($0, maximumBytes: 90_000)
        }
        accountEnvelope = try ProviderSQL.decode(row.decode(column: "account_envelope", as: String.self), maximumBytes: 2048)
        guard generation > 0, credentialVersion > 0,
              let status = Status(rawValue: try row.decode(column: "status", as: String.self)),
              let refresh = RefreshState(rawValue: try row.decode(column: "refresh_state", as: String.self)) else {
            throw ProviderFailure.unavailable
        }
        self.status = status
        refreshState = refresh
        refreshID = try row.decode(column: "refresh_id", as: UUID?.self)
        lastAttempt = try row.decode(column: "last_attempt", as: Date?.self)
        lastSuccessfulFetch = try row.decode(column: "last_successful_fetch", as: Date?.self)
        nextAttempt = try row.decode(column: "next_attempt", as: Date.self)
        dormantUntil = try row.decode(column: "dormant_until", as: Date.self)
    }
}
