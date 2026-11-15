//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Fluent
import Foundation
import Grove
import SQLKit


final class ProviderConnectionService: Module, Sendable {
    struct LinkIntent: Sendable {
        let id: UUID
        let authorizationURL: URL
        let redirectURI: URL
        let expiresAt: Date
    }

    struct Status: Sendable {
        let id: UUID
        let registrationID: UUID
        let sourceID: UUID
        let state: ProviderConnection.Status
        let generation: Int64
        let lastAttempt: Date?
        let lastSuccessfulFetch: Date?
        let acceptedThrough: Date?
        let requiresReauthorization: Bool
        var collectionAttempt: CollectionAttempt?
    }

    let database: any Database
    let vault: ProviderCredentialVault
    let sourceKeyring: SourceIdentityKeyring
    let authorization: any ProviderAuthorizationClient
    let dormantRetention: TimeInterval

    init(
        database: any Database,
        vault: ProviderCredentialVault,
        sourceKeyring: SourceIdentityKeyring,
        authorization: any ProviderAuthorizationClient,
        dormantRetention: TimeInterval = 86_400
    ) throws {
        guard dormantRetention.isFinite, (0...2_592_000).contains(dormantRetention) else { throw ProviderFailure.invalidConfiguration }
        self.database = database
        self.vault = vault
        self.sourceKeyring = sourceKeyring
        self.authorization = authorization
        self.dormantRetention = dormantRetention
    }

    func start(registrationID: UUID, redirectID: String, now: Date = Date()) async throws -> LinkIntent {
        let actor = try AuthContext.checkIsParticipant()
        return try await database.transaction { transaction in
            let participantID = try await SourceBindingService.lockParticipant(actor, on: transaction)
            let approved = try await ProviderRegistrationStore.requireApproved(registrationID, on: transaction, lock: true)
            let registration = approved.configuration
            let redirect = try registration.redirect(id: redirectID)
            let id = UUID()
            let state = Self.randomSecret()
            let verifier = Self.randomSecret()
            let expiresAt = now.addingTimeInterval(600)
            let url = try Self.authorizationURL(registration, redirect: redirect, state: state, verifier: verifier)
            let envelope = try self.vault.seal(Data(verifier.utf8), context: .init(
                participantID: participantID, registrationID: registrationID, recordID: id, version: 1, purpose: .authorizationVerifier
            ))
            let sql = try ProviderSQL.sql(transaction)
            let count = try await sql.raw("""
                SELECT COUNT(*) AS count FROM provider_link_intents
                WHERE participant_id = \(bind: participantID) AND status = 'pending' AND expires_at > \(bind: now)
                """).first()
            guard let count, try count.decode(column: "count", as: Int.self) < 16 else { throw ProviderFailure.capacityExceeded }
            try await sql.raw("""
                INSERT INTO provider_link_intents (
                    id, participant_id, registration_id, registration_generation, redirect_id, state_digest,
                    verifier_envelope, expires_at, status
                ) VALUES (
                    \(bind: id), \(bind: participantID), \(bind: registrationID), \(bind: approved.generation),
                    \(bind: redirectID), \(bind: Self.digest(state)), \(bind: try ProviderSQL.encode(envelope)), \(bind: expiresAt), 'pending'
                )
                """).run()
            try await AuditRepository.recordMutation(.init(
                context: actor.auditContext, action: .providerLinkStarted,
                scope: .participantProvider(participantID: participantID, registrationID: registrationID), target: .init(id: id)
            ), on: transaction)
            return LinkIntent(id: id, authorizationURL: url, redirectURI: redirect, expiresAt: expiresAt)
        }
    }

    func disconnect(id: UUID) async throws -> Status {
        let actor = try AuthContext.checkIsParticipant()
        return try await database.transaction { transaction in
            let participantID = try await SourceBindingService.lockParticipant(actor, on: transaction)
            let connection = try await ProviderSQL.connection(id, on: transaction)
            guard connection.participantID == participantID else { throw ProviderFailure.fenced }
            if connection.status != .disconnected {
                guard connection.generation < Int64.max else { throw ProviderFailure.unavailable }
                let sql = try ProviderSQL.sql(transaction)
                try await sql.raw("""
                    UPDATE provider_connections SET status = 'disconnected', generation = generation + 1,
                        credential_envelope = NULL, refresh_state = 'ready', refresh_id = NULL WHERE id = \(bind: id)
                    """).run()
                try await sql.raw("""
                    UPDATE provider_checkpoints SET status = 'blocked', lease_id = NULL, lease_until = NULL
                    WHERE connection_id = \(bind: id) AND status <> 'complete'
                    """).run()
                try await AuditRepository.recordMutation(.init(
                    context: actor.auditContext, action: .providerConnectionDisconnected,
                    scope: .participantProvider(participantID: participantID, registrationID: connection.registrationID),
                    target: .init(id: id, version: String(connection.generation + 1))
                ), on: transaction)
            }
            return try await Self.status(ProviderSQL.connection(id, on: transaction), on: transaction)
        }
    }
}


extension ProviderConnectionService {
    static func randomSecret() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func authorizationURL(_ registration: ProviderRegistration, redirect: URL, state: String, verifier: String) throws -> URL {
        guard var components = URLComponents(url: registration.provider.authorizationURL, resolvingAgainstBaseURL: false) else {
            throw ProviderFailure.invalidConfiguration
        }
        components.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: registration.clientID),
            .init(name: "redirect_uri", value: redirect.absoluteString), .init(name: "state", value: state),
            .init(name: "scope", value: registration.scopes.sorted().joined(separator: registration.provider == .withings ? "," : " "))
        ]
        if registration.supportsPKCE {
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            components.queryItems?.append(contentsOf: [
                .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: challenge)
            ])
        }
        if registration.provider == .googleHealthAPI {
            components.queryItems?.append(contentsOf: [.init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent")])
        }
        guard let url = components.url, url.absoluteString.utf8.count <= 8192 else { throw ProviderFailure.invalidConfiguration }
        return url
    }

    static func status(_ connection: ProviderConnection, on database: any Database) async throws -> Status {
        let row = try await ProviderSQL.sql(database).raw("""
            SELECT CASE WHEN COUNT(accepted_through) = COUNT(*) THEN MIN(accepted_through) ELSE NULL END AS accepted_through
            FROM provider_checkpoints WHERE connection_id = \(bind: connection.id)
            """).first()
        return Status(
            id: connection.id, registrationID: connection.registrationID, sourceID: connection.sourceID,
            state: connection.status, generation: connection.generation, lastAttempt: connection.lastAttempt,
            lastSuccessfulFetch: connection.lastSuccessfulFetch,
            acceptedThrough: try row?.decode(column: "accepted_through", as: Date?.self),
            requiresReauthorization: connection.status == .reauthorizationRequired || connection.refreshState != .ready,
            collectionAttempt: try await collectionAttempt(connection, on: database)
        )
    }
}
