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
    private enum Completion: Sendable {
        case replay(Status)
        case exchange(Prepared)
    }

    private struct Prepared: Sendable {
        let id: UUID
        let participantID: UUID
        let approved: ProviderRegistrationStore.Approved
        let redirect: URL
        let verifier: String?
    }

    func complete(id: UUID, state: String, code: String, now: Date = Date()) async throws -> Status {
        let actor = try AuthContext.checkIsParticipant()
        guard (32...128).contains(state.utf8.count), (1...4096).contains(code.utf8.count) else { throw ProviderFailure.invalidLink }
        let completion = try await prepare(id: id, state: state, actor: actor, now: now)
        switch completion {
        case .replay(let status): return status
        case .exchange(let prepared):
            do {
                let credentials = try await authorization.exchange(
                    registration: prepared.approved.configuration, code: code, redirect: prepared.redirect, verifier: prepared.verifier
                )
                try credentials.validate(requiredScopes: prepared.approved.configuration.scopes, at: Date())
                try Task.checkCancellation()
                return try await commit(credentials, prepared: prepared, actor: actor)
            } catch {
                // Once dispatch is durable, neither a timeout nor a database error permits sending the code again.
                try? await markUncertain(prepared, actor: actor)
                try Task.checkCancellation()
                if let failure = error as? ProviderFailure { throw failure }
                throw ProviderFailure.reauthorizationRequired
            }
        }
    }

    private func prepare(id: UUID, state: String, actor: AuthContext, now: Date) async throws -> Completion {
        try await database.transaction { transaction in
            let participantID = try await SourceBindingService.lockParticipant(actor, on: transaction)
            let sql = try ProviderSQL.sql(transaction)
            guard let row = try await sql.raw("""
                SELECT * FROM provider_link_intents
                WHERE id = \(bind: id) AND participant_id = \(bind: participantID) AND state_digest = \(bind: Self.digest(state))
                """)
                .first() else { throw ProviderFailure.invalidLink }
            let status = try row.decode(column: "status", as: String.self)
            if status == "complete", let connectionID = try row.decode(column: "connection_id", as: UUID?.self) {
                return try await .replay(Self.status(ProviderSQL.connection(connectionID, on: transaction), on: transaction))
            }
            guard status == "pending" else { throw ProviderFailure.reauthorizationRequired }
            guard try row.decode(column: "expires_at", as: Date.self) > now else { throw ProviderFailure.invalidLink }
            let registrationID = try row.decode(column: "registration_id", as: UUID.self)
            let approved = try await ProviderRegistrationStore.requireApproved(registrationID, on: transaction, lock: true)
            guard approved.generation == (try row.decode(column: "registration_generation", as: Int64.self)) else {
                throw ProviderFailure.fenced
            }
            let verifier = try self.verifier(row, participantID: participantID, registrationID: registrationID, id: id)
            try await sql.raw("UPDATE provider_link_intents SET status = 'dispatched' WHERE id = \(bind: id)").run()
            try await AuditRepository.recordMutation(.init(
                context: actor.auditContext,
                action: .providerLinkDispatched,
                scope: .participantProvider(participantID: participantID, registrationID: registrationID),
                target: .init(id: id)
            ), on: transaction)
            return .exchange(Prepared(
                id: id,
                participantID: participantID,
                approved: approved,
                redirect: try approved.configuration.redirect(id: row.decode(column: "redirect_id", as: String.self)),
                verifier: approved.configuration.supportsPKCE ? verifier : nil
            ))
        }
    }

    private func verifier(_ row: any SQLRow, participantID: UUID, registrationID: UUID, id: UUID) throws -> String {
        let envelope: ProviderCredentialVault.Envelope = try ProviderSQL.decode(row.decode(column: "verifier_envelope", as: String.self))
        let bytes = try vault.open(envelope, context: .init(
            participantID: participantID, registrationID: registrationID, recordID: id, version: 1, purpose: .authorizationVerifier
        ))
        guard let verifier = String(data: bytes, encoding: .utf8), verifier.utf8.count == 43 else {
            throw ProviderFailure.unavailable
        }
        return verifier
    }

    private func commit(_ credentials: ProviderCredentials, prepared: Prepared, actor: AuthContext) async throws -> Status {
        try await database.transaction { transaction in
            try await ProviderSQL.lockParticipant(prepared.participantID, on: transaction)
            let approved = try await ProviderRegistrationStore.requireApproved(prepared.approved.configuration.id, on: transaction, lock: true)
            guard approved.generation == prepared.approved.generation else { throw ProviderFailure.fenced }
            let sql = try ProviderSQL.sql(transaction)
            guard let row = try await sql.raw("""
                SELECT id FROM provider_link_intents WHERE id = \(bind: prepared.id) AND status = 'dispatched'
                """)
                .first(), try row.decode(column: "id", as: UUID.self) == prepared.id else { throw ProviderFailure.fenced }
            let connection = try await self.connect(
                credentials, participantID: prepared.participantID, registration: approved.configuration, actor: actor, on: transaction
            )
            try await sql.raw("""
                UPDATE provider_link_intents SET status = 'complete', connection_id = \(bind: connection.id)
                WHERE id = \(bind: prepared.id)
                """)
                .run()
            try await AuditRepository.recordMutation(.init(
                context: actor.auditContext,
                action: .providerLinkCompleted,
                scope: .participantProvider(participantID: prepared.participantID, registrationID: approved.configuration.id),
                target: .init(id: connection.id, version: String(connection.generation))
            ), on: transaction)
            return try await Self.status(connection, on: transaction)
        }
    }

    private func markUncertain(_ prepared: Prepared, actor: AuthContext) async throws {
        try await database.transaction { transaction in
            try await ProviderSQL.lockParticipant(prepared.participantID, on: transaction)
            let row = try await ProviderSQL.sql(transaction)
                .raw("""
                    UPDATE provider_link_intents SET status = 'uncertain'
                    WHERE id = \(bind: prepared.id) AND status = 'dispatched' RETURNING id
                    """)
                .first()
            guard row != nil else {
                return
            }
            try await AuditRepository.recordMutation(.init(
                context: actor.auditContext,
                action: .providerCredentialUncertain,
                scope: .participantProvider(participantID: prepared.participantID, registrationID: prepared.approved.configuration.id),
                target: .init(id: prepared.id)
            ), on: transaction)
        }
    }
}
