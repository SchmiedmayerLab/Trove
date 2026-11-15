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


/// A dispatched refresh is never automatically retried: its upstream rotation may already have happened.
struct ProviderCredentialService: Sendable {
    private struct Dispatch: Sendable {
        let connection: ProviderConnection
        let registration: ProviderRegistration
        let credentials: ProviderCredentials
        let refreshID: UUID?
        let audit: AuditEvent.Context
    }

    let database: any Database
    let vault: ProviderCredentialVault
    let authorization: any ProviderAuthorizationClient

    func credentials(for authority: ProviderWorkerAuthority, now: Date = Date()) async throws -> ProviderCredentials {
        let dispatch = try await prepare(authority, now: now)
        guard let refreshID = dispatch.refreshID else {
            return dispatch.credentials
        }
        do {
            let refreshed = try await authorization.refresh(registration: dispatch.registration, credentials: dispatch.credentials)
            try refreshed.validate(requiredScopes: dispatch.registration.scopes, at: Date())
            guard refreshed.accountID == dispatch.credentials.accountID,
                  dispatch.registration.scopes.isSubset(of: refreshed.scopes) else { throw ProviderFailure.scopeLost }
            return try await database.transaction { transaction in
                _ = try await authority.lock(on: transaction)
                let current = try await ProviderSQL.connection(authority.connectionID, on: transaction)
                guard current.refreshState == .dispatched, current.refreshID == refreshID,
                      current.credentialVersion == dispatch.connection.credentialVersion,
                      current.credentialVersion < Int64.max else { throw ProviderFailure.fenced }
                let version = current.credentialVersion + 1
                let context = ProviderCredentialVault.Context(
                    participantID: current.participantID,
                    registrationID: current.registrationID,
                    recordID: current.id,
                    version: version,
                    purpose: .participantCredential
                )
                let bytes = Data(try ProviderSQL.encode(refreshed, maximumBytes: 65_536).utf8)
                let sealed = try ProviderSQL.encode(self.vault.seal(bytes, context: context), maximumBytes: 90_000)
                try await ProviderSQL.sql(transaction)
                    .raw("""
                        UPDATE provider_connections SET credential_version = \(bind: version), credential_envelope = \(bind: sealed),
                            refresh_state = 'ready', refresh_id = NULL WHERE id = \(bind: current.id)
                        """)
                    .run()
                try await AuditRepository.recordMutation(.init(
                    context: dispatch.audit,
                    action: .providerCredentialRotated,
                    scope: .participantProvider(participantID: current.participantID, registrationID: current.registrationID),
                    target: .init(id: current.id, version: String(version))
                ), on: transaction)
                return refreshed
            }
        } catch {
            try await uncertain(dispatch, refreshID: refreshID)
            if error is CancellationError { throw CancellationError() }
            throw ProviderFailure.reauthorizationRequired
        }
    }

    private func prepare(_ authority: ProviderWorkerAuthority, now: Date) async throws -> Dispatch {
        try await database.transaction { transaction in
            let authorized = try await authority.lock(on: transaction, now: now)
            let connection = try await ProviderSQL.connection(authority.connectionID, on: transaction)
            let approved = try await ProviderRegistrationStore.requireApproved(authority.registrationID, on: transaction)
            guard connection.refreshState == .ready, let envelope = connection.credentialEnvelope else {
                throw ProviderFailure.reauthorizationRequired
            }
            let bytes = try self.vault.open(envelope, context: connection.credentialContext)
            let credentials: ProviderCredentials
            do { credentials = try JSONDecoder().decode(ProviderCredentials.self, from: bytes) } catch { throw ProviderFailure.unavailable }
            guard approved.configuration.scopes.isSubset(of: credentials.scopes) else { throw ProviderFailure.scopeLost }
            // Credentials that remain valid beyond the dispatch need no refresh fence.
            let refreshID: UUID? = credentials.expiresAt > now.addingTimeInterval(120) ? nil : UUID()
            if let refreshID {
                try await ProviderSQL.sql(transaction)
                    .raw("""
                        UPDATE provider_connections SET refresh_state = 'dispatched', refresh_id = \(bind: refreshID), last_attempt = \(bind: now)
                        WHERE id = \(bind: connection.id)
                        """)
                    .run()
                try await AuditRepository.recordMutation(.init(
                    context: authorized.audit,
                    action: .providerRefreshDispatched,
                    scope: .participantProvider(participantID: connection.participantID, registrationID: connection.registrationID),
                    target: .init(id: refreshID, version: String(connection.credentialVersion))
                ), on: transaction)
            }
            return Dispatch(
                connection: connection,
                registration: approved.configuration,
                credentials: credentials,
                refreshID: refreshID,
                audit: authorized.audit
            )
        }
    }

    private func uncertain(_ dispatch: Dispatch, refreshID: UUID) async throws {
        try await database.transaction { transaction in
            try await ProviderSQL.lockParticipant(dispatch.connection.participantID, on: transaction)
            let current = try await ProviderSQL.connection(dispatch.connection.id, on: transaction)
            // Disconnect/relink supersedes this refresh. Never overwrite its new credentials or status.
            guard current.generation == dispatch.connection.generation,
                  current.credentialVersion == dispatch.connection.credentialVersion,
                  current.refreshState == .dispatched, current.refreshID == refreshID else { return }
            try await ProviderSQL.sql(transaction)
                .raw("""
                    UPDATE provider_connections SET refresh_state = 'uncertain', status = 'reauthorization-required',
                        credential_envelope = NULL WHERE id = \(bind: current.id)
                    """)
                .run()
            try await AuditRepository.recordMutation(.init(
                context: dispatch.audit,
                action: .providerCredentialUncertain,
                scope: .participantProvider(participantID: current.participantID, registrationID: current.registrationID),
                target: .init(id: current.id, version: String(current.credentialVersion))
            ), on: transaction)
        }
    }
}
