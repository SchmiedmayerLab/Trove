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


extension ProviderWorkerStore {
    /// The failure count, failure kind and next attempt that follow one finished dispatch.
    private struct Retry {
        let count: Int
        let kind: String?
        let next: Date

        init(_ outcome: Outcome, previous: Int, now: Date) {
            guard case .failed(let failure) = outcome else {
                count = 0
                kind = nil
                next = now.addingTimeInterval(60)
                return
            }
            count = min(previous + 1, ProviderCheckpoint.maximumFailures)
            kind = failure.kind
            if case .transient(let retryAfter) = failure {
                next = max(now.addingTimeInterval(min(60 * pow(2, Double(count - 1)), 86_400)), retryAfter ?? now)
            } else {
                // Retained rows and checkpoints remain intact; a recoverable configuration/authority change can be rechecked.
                next = now.addingTimeInterval(3600)
            }
        }
    }

    enum Outcome: Sendable {
        case accepted
        case idle
        case deferred
        case failed(Failure)

        var value: String {
            switch self {
            case .accepted: "accepted"
            case .idle: "idle"
            case .deferred: "deferred"
            case .failed: "failed"
            }
        }
    }

    enum Failure: Sendable {
        case transient(Date?)
        case capacity
        case source
        case authority

        var kind: String {
            switch self {
            case .transient: "transient"
            case .capacity: "capacity"
            case .source: "source"
            case .authority: "authority"
            }
        }

        static func classify(_ error: any Error) -> Self {
            if let retry = error as? ProviderTransportRetry {
                return .transient(retry.notBefore)
            }
            switch error as? ProviderFailure {
            case .capacityExceeded: return .capacity
            case .invalidPayload, .invalidConfiguration: return .source
            case .scopeLost, .fenced, .reauthorizationRequired, .ambiguousAccount: return .authority
            default: return .transient(nil)
            }
        }
    }

    func finished(_ candidate: Candidate, sourceToken: String, outcome: Outcome, now: Date) async throws {
        try await database.transaction { transaction in
            try await ProviderSQL.lockParticipant(candidate.connection.participantID, on: transaction)
            let sql = try ProviderSQL.sql(transaction)
            guard let row = try await sql.raw("""
                SELECT s.failure_count FROM provider_worker_states s JOIN provider_connections c ON c.id = s.connection_id
                WHERE c.id = \(bind: candidate.connection.id) AND c.generation = \(bind: candidate.connection.generation)
                    AND (c.last_attempt IS NULL OR c.last_attempt <= \(bind: now))
                """)
                .first() else { return }
            let previous = try row.decode(column: "failure_count", as: Int.self)
            if case .failed = outcome {
                try await recordFailure(connectionID: candidate.connection.id, sourceToken: sourceToken, on: sql)
            }
            let retry = Retry(outcome, previous: previous, now: now)
            try await sql.raw("""
                UPDATE provider_worker_states SET failure_count = \(bind: retry.count), failure_kind = \(bind: retry.kind),
                    outcome = \(bind: outcome.value)
                WHERE connection_id = \(bind: candidate.connection.id)
                """)
                .run()
            try await sql.raw("""
                UPDATE provider_connections SET next_attempt = \(bind: retry.next) WHERE id = \(bind: candidate.connection.id)
                """)
                .run()
        }
    }

    private func recordFailure(connectionID: UUID, sourceToken: String, on sql: any SQLDatabase) async throws {
        try await sql.raw("""
            UPDATE provider_checkpoints SET failure_count = failure_count + 1,
                status = CASE WHEN failure_count + 1 >= \(bind: ProviderCheckpoint.maximumFailures) THEN 'blocked' ELSE status END,
                lease_id = CASE WHEN failure_count + 1 >= \(bind: ProviderCheckpoint.maximumFailures) THEN NULL ELSE lease_id END,
                lease_until = CASE WHEN failure_count + 1 >= \(bind: ProviderCheckpoint.maximumFailures) THEN NULL ELSE lease_until END
            WHERE connection_id = \(bind: connectionID) AND source_token = \(bind: sourceToken)
                AND status IN ('fetching', 'staged') AND failure_count < \(bind: ProviderCheckpoint.maximumFailures)
            """)
            .run()
    }
}
