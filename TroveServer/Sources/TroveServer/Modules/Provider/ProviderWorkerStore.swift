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


/// Operational scheduling state never grants access to clinical data; ingestion rechecks its own authority.
struct ProviderWorkerStore: Sendable {
    struct Candidate: Sendable {
        let connection: ProviderConnection
        let registration: ProviderRegistration
    }

    let database: any Database
    let registrationIDs: Set<UUID>
    let minimumDispatchInterval: TimeInterval

    func candidates(now: Date) async throws -> [Candidate] {
        guard !registrationIDs.isEmpty else {
            return []
        }
        let rows = try await ProviderSQL.sql(database)
            .raw("""
                SELECT c.*, r.configuration AS registration_configuration FROM provider_connections c
                JOIN provider_registrations r ON r.id = c.registration_id
                WHERE r.approved = \(bind: true) AND c.registration_id IN (\(binds: registrationIDs.sorted { $0.uuidString < $1.uuidString }))
                    AND c.status <> 'disconnected' AND c.next_attempt <= \(bind: now)
                    AND ((c.status = 'active' AND c.refresh_state = 'ready') OR EXISTS (
                        SELECT 1 FROM provider_checkpoints p WHERE p.connection_id = c.id AND p.status = 'staged') OR EXISTS (
                        SELECT 1 FROM provider_staged_records retained
                        JOIN provider_checkpoints checkpoint ON checkpoint.id = retained.checkpoint_id
                        JOIN provider_connections origin ON origin.id = checkpoint.connection_id
                        WHERE retained.event_id IS NOT NULL AND origin.source_id = c.source_id
                            AND origin.participant_id = c.participant_id AND origin.account_pseudonym = c.account_pseudonym))
                ORDER BY c.next_attempt, c.last_attempt, c.id LIMIT 32
                """)
            .all()
        return try rows.map {
            Candidate(
                connection: try .init(row: $0),
                registration: try ProviderSQL.decode($0.decode(column: "registration_configuration", as: String.self))
            )
        }
    }

    /// A committed provider-wide slot spans processes. Losing a process can waste a slot, never multiply it.
    func claim(_ candidate: Candidate, tokens: Set<String>, now: Date) async throws -> String? {
        guard minimumDispatchInterval.isFinite, (1...3600).contains(minimumDispatchInterval), !tokens.isEmpty else {
            throw ProviderFailure.invalidConfiguration
        }
        return try await database.transaction { transaction in
            let sql = try ProviderSQL.sql(transaction)
            let slots = try await sql.raw("""
                UPDATE provider_dispatch_budgets SET not_before = \(bind: now.addingTimeInterval(minimumDispatchInterval))
                WHERE provider = \(bind: candidate.registration.provider.rawValue) AND not_before <= \(bind: now) RETURNING provider
                """)
                .all()
            guard !slots.isEmpty else {
                return nil
            }
            try await sql.raw("""
                INSERT INTO provider_worker_states (connection_id, failure_count, outcome) VALUES (\(bind: candidate.connection.id), 0, 'scheduled')
                ON CONFLICT (connection_id) DO NOTHING
                """)
                .run()
            let row = try await sql.raw("""
                SELECT last_source_token FROM provider_worker_states WHERE connection_id = \(bind: candidate.connection.id)
                """)
                .first()
            let previous = try row?.decode(column: "last_source_token", as: String?.self)
            let sorted = tokens.sorted()
            guard let token = sorted.first(where: { token in previous.map { $0 < token } ?? true }) ?? sorted.first else {
                throw ProviderFailure.invalidConfiguration
            }
            try await sql.raw("""
                UPDATE provider_worker_states SET last_source_token = \(bind: token), outcome = 'scheduled' WHERE connection_id = \(bind: candidate.connection.id)
                """)
                .run()
            return token
        }
    }
}
