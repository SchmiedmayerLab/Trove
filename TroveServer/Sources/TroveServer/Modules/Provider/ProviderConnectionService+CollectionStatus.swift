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
    struct CollectionAttempt: Sendable {
        enum Outcome: String, Sendable {
            case scheduled
            case deferred
            case accepted
            case noCurrentDemand = "no-current-demand"
            case transientFailure = "transient-failure"
            case capacityBlocked = "capacity-blocked"
            case sourceBlocked = "source-blocked"
            case authorizationChanged = "authorization-changed"
        }

        let sourceTypeIdentifier: String
        let outcome: Outcome
        let nextAttempt: Date
    }

    /// Reports one exact source's latest attempt, never a claim that every source on the account is caught up.
    static func collectionAttempt(_ connection: ProviderConnection, on database: any Database) async throws -> CollectionAttempt? {
        guard let row = try await ProviderSQL.sql(database).raw("""
            SELECT last_source_token, outcome, failure_kind FROM provider_worker_states WHERE connection_id = \(bind: connection.id)
            """).first() else { return nil }
        let source = try row.decode(column: "last_source_token", as: String.self)
        let outcome: CollectionAttempt.Outcome
        switch try row.decode(column: "outcome", as: String.self) {
        case "scheduled": outcome = .scheduled
        case "deferred": outcome = .deferred
        case "accepted": outcome = .accepted
        case "idle": outcome = .noCurrentDemand
        case "failed": outcome = try failureOutcome(row.decode(column: "failure_kind", as: String.self))
        default: throw ProviderFailure.unavailable
        }
        return .init(sourceTypeIdentifier: source, outcome: outcome, nextAttempt: connection.nextAttempt)
    }

    private static func failureOutcome(_ kind: String) throws -> CollectionAttempt.Outcome {
        switch kind {
        case "transient": .transientFailure
        case "capacity": .capacityBlocked
        case "source": .sourceBlocked
        case "authority": .authorizationChanged
        default: throw ProviderFailure.unavailable
        }
    }
}
