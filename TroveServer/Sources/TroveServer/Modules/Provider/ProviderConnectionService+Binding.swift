//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import SQLKit


extension ProviderConnectionService {
    /// Upstream account identity is verified by the OAuth adapter, never supplied by a participant request.
    func connect(
        _ credentials: ProviderCredentials,
        participantID: UUID,
        registration: ProviderRegistration,
        actor: AuthContext,
        on database: any Database
    ) async throws -> ProviderConnection {
        guard database.inTransaction else { throw AuditError.transactionRequired }
        let sql = try ProviderSQL.sql(database)
        let rows = try await sql.raw("""
            SELECT * FROM provider_connections
            WHERE participant_id = \(bind: participantID) AND registration_id = \(bind: registration.id)
            ORDER BY created_at, id LIMIT 129
            """)
            .all()
        guard rows.count <= 128 else { throw ProviderFailure.capacityExceeded }
        var matching: ProviderConnection?
        for row in rows {
            let connection = try ProviderConnection(row: row)
            let identity = try vault.open(connection.accountEnvelope, context: connection.accountContext)
            guard let accountID = String(data: identity, encoding: .utf8) else { throw ProviderFailure.unavailable }
            if accountID == credentials.accountID {
                guard matching == nil else { throw ProviderFailure.unavailable }
                matching = connection
            } else if connection.status != .disconnected {
                throw ProviderFailure.ambiguousAccount
            }
        }
        if let matching {
            return try await reconnect(matching, credentials: credentials, registration: registration, on: database)
        }
        return try await createConnection(credentials, participantID: participantID, registration: registration, actor: actor, on: database)
    }

    private func reconnect(
        _ matching: ProviderConnection, credentials: ProviderCredentials, registration: ProviderRegistration, on database: any Database
    ) async throws -> ProviderConnection {
        let participantID = matching.participantID
        let sql = try ProviderSQL.sql(database)
        guard matching.generation < Int64.max, matching.credentialVersion < Int64.max else { throw ProviderFailure.unavailable }
        // Recovery must establish the original identity before any connection can be reactivated.
        _ = try await SourceIdentityKeyStore(keyring: sourceKeyring).recover(
            sourceID: matching.sourceID, participantID: participantID, on: database
        )
        let version = matching.credentialVersion + 1
        let context = ProviderCredentialVault.Context(
            participantID: participantID,
            registrationID: registration.id,
            recordID: matching.id,
            version: version,
            purpose: .participantCredential
        )
        let sealed = try credentialEnvelope(credentials, context: context)
        let account = try vault.seal(identityBytes(credentials), context: matching.accountContext)
        try await sql.raw("""
            UPDATE provider_connections SET generation = generation + 1, credential_version = \(bind: version),
                credential_envelope = \(bind: sealed), account_envelope = \(bind: try ProviderSQL.encode(account)),
                status = 'active', refresh_state = 'ready', refresh_id = NULL, next_attempt = \(bind: Date()),
                dormant_until = \(bind: Date().addingTimeInterval(dormantRetention)) WHERE id = \(bind: matching.id)
            """)
            .run()
        try await sql.raw("""
            UPDATE provider_checkpoints SET status = 'blocked', lease_id = NULL, lease_until = NULL
            WHERE connection_id = \(bind: matching.id) AND status <> 'complete'
            """)
            .run()
        return try await ProviderSQL.connection(matching.id, on: database)
    }

    private func createConnection(
        _ credentials: ProviderCredentials,
        participantID: UUID,
        registration: ProviderRegistration,
        actor: AuthContext,
        on database: any Database
    ) async throws -> ProviderConnection {
        let sql = try ProviderSQL.sql(database)
        let source = try await ProviderSourceStore.create(
            participantID: participantID, registration: registration, actor: actor, keyring: sourceKeyring, on: database
        )
        let pseudonym = try await accountPseudonym(credentials, participantID: participantID, sourceID: source.id, on: database)
        let id = UUID()
        let context = ProviderCredentialVault.Context(
            participantID: participantID, registrationID: registration.id, recordID: id, version: 1, purpose: .participantCredential
        )
        let account = try vault.seal(identityBytes(credentials), context: .init(
            participantID: participantID, registrationID: registration.id, recordID: id, version: 1, purpose: .accountIdentity
        ))
        try await sql.raw("""
            INSERT INTO provider_connections (
                id, participant_id, registration_id, source_id, account_pseudonym, generation, credential_version,
                credential_envelope, account_envelope, status, refresh_state, created_at, next_attempt, dormant_until
            ) VALUES (
                \(bind: id), \(bind: participantID), \(bind: registration.id), \(bind: source.id), \(bind: pseudonym), 1, 1,
                \(bind: try credentialEnvelope(credentials, context: context)), \(bind: try ProviderSQL.encode(account)),
                'active', 'ready', \(bind: Date()), \(bind: Date()), \(bind: Date().addingTimeInterval(dormantRetention))
            )
            """)
            .run()
        return try await ProviderSQL.connection(id, on: database)
    }

    func credentialEnvelope(_ credentials: ProviderCredentials, context: ProviderCredentialVault.Context) throws -> String {
        let encoded = try ProviderSQL.encode(credentials, maximumBytes: 65_536)
        return try ProviderSQL.encode(vault.seal(Data(encoded.utf8), context: context), maximumBytes: 90_000)
    }

    private func identityBytes(_ credentials: ProviderCredentials) -> Data {
        Data(credentials.accountID.utf8)
    }
}
