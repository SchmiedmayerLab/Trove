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


/// Retirement removes reusable credentials only. Logical identities, account binding and retained custody remain intact.
struct ProviderCredentialRetirement: Sendable {
    let database: any Database
    let registrationIDs: Set<UUID>
    let worker: ProviderWorkerIdentity
    let retention: TimeInterval

    func run(now: Date = Date()) async throws {
        guard !registrationIDs.isEmpty else {
            return
        }
        let rows = try await ProviderSQL.sql(database)
            .raw("""
            SELECT id, participant_id FROM provider_connections
            WHERE registration_id IN (\(binds: registrationIDs.sorted { $0.uuidString < $1.uuidString }))
                AND credential_envelope IS NOT NULL AND dormant_until <= \(bind: now)
            ORDER BY dormant_until, id LIMIT 32
            """)
            .all()
        for row in rows {
            try Task.checkCancellation()
            try await retire(
                id: row.decode(column: "id", as: UUID.self), participantID: row.decode(column: "participant_id", as: UUID.self), now: now
            )
        }
    }

    private func retire(id: UUID, participantID: UUID, now: Date) async throws {
        try await database.transaction { transaction in
            try await ProviderSQL.lockParticipant(participantID, on: transaction)
            let connection = try await ProviderSQL.connection(id, on: transaction)
            guard connection.credentialEnvelope != nil, connection.dormantUntil <= now else {
                return
            }
            let sql = try ProviderSQL.sql(transaction)
            guard let registration = try await sql.raw("""
                UPDATE provider_registrations SET generation = generation WHERE id = \(bind: connection.registrationID) RETURNING *
                """)
                .first() else { throw ProviderFailure.fenced }
            let configuration: ProviderRegistration = try ProviderSQL.decode(registration.decode(column: "configuration", as: String.self))
            if try registration.decode(column: "approved", as: Bool.self),
               try await hasDemand(participantID: participantID, registration: configuration, now: now, on: transaction) {
                try await sql.raw("""
                    UPDATE provider_connections SET dormant_until = \(bind: now.addingTimeInterval(max(retention, 60))) WHERE id = \(bind: id)
                    """)
                    .run()
                return
            }
            let audit = try await worker.audit(participantID: participantID, on: transaction)
            try await sql.raw("""
                UPDATE provider_connections SET credential_envelope = NULL,
                    status = CASE WHEN status = 'disconnected' THEN status ELSE 'reauthorization-required' END,
                    refresh_state = 'uncertain' WHERE id = \(bind: id)
                """)
                .run()
            try await AuditRepository.recordMutation(.init(
                context: audit,
                action: .providerCredentialRetired,
                scope: .participantProvider(participantID: participantID, registrationID: connection.registrationID),
                target: .init(id: id, version: String(connection.credentialVersion))
            ), on: transaction)
        }
    }

    private func hasDemand(
        participantID: UUID, registration: ProviderRegistration, now: Date, on database: any Database
    ) async throws -> Bool {
        for token in registration.sourceTokens.sorted() {
            if try await !ProviderDemandStore.load(
                participantID: participantID,
                registration: registration,
                sourceToken: token,
                asOf: now,
                purpose: .acquisition,
                on: database
            ).isEmpty { return true }
            let closed = try await ProviderDemandStore.load(
                participantID: participantID,
                registration: registration,
                sourceToken: token,
                asOf: now,
                purpose: .closedWindowReconciliation,
                on: database
            )
            guard !closed.isEmpty else { continue }
            let connections = try await ProviderSQL.sql(database)
            .raw("""
                SELECT id FROM provider_connections WHERE participant_id = \(bind: participantID)
                    AND registration_id = \(bind: registration.id) AND status <> 'disconnected'
                """)
            .all()
            for row in connections {
                let store = try await ProviderCheckpointStore(
                    connectionID: row.decode(column: "id", as: UUID.self), sourceToken: token, sql: ProviderSQL.sql(database)
                )
                if try await store.hasPending(purpose: .reconciliation) {
                    return true
                }
                if try await store.remainingWindow(demands: closed, purpose: .reconciliation) != nil {
                    return true
                }
            }
        }
        return false
    }
}
