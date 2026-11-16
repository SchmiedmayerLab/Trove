//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SQLKit


/// Immutable query evidence is indexed separately from the exact checkpoint retry representation.
struct ProviderCoverageStore {
    let connectionID: UUID
    let sourceToken: String
    let sql: any SQLDatabase

    func next(demands: [ProviderDemand], purpose: ProviderCheckpoint.Purpose) async throws -> Range<Date>? {
        var result: Range<Date>?
        for profile in Set(demands.map(\.profile)).sorted() {
            for window in ProviderDemandStore.windows(demands.filter { $0.profile == profile }) {
                guard let gap = try await firstGap(profile: profile, window: window, purpose: purpose) else { continue }
                if result.map({ gap.lowerBound < $0.lowerBound || (gap.lowerBound == $0.lowerBound && gap.upperBound < $0.upperBound) }) ?? true {
                    result = gap
                }
                break
            }
        }
        return result.map { $0.lowerBound..<min($0.upperBound, $0.lowerBound.addingTimeInterval(86_400)) }
    }

    func selection(demands: [ProviderDemand], window: Range<Date>, purpose: ProviderCheckpoint.Purpose) async throws -> ProviderQueryCoverage {
        var uncovered: [ProviderDemand] = []
        for demand in demands {
            var start = max(demand.start, window.lowerBound)
            let end = min(demand.end, window.upperBound)
            while start < end, let gap = try await firstGap(profile: demand.profile, window: start..<end, purpose: purpose) {
                uncovered.append(try ProviderDemand(
                    consentID: demand.consentID, profile: demand.profile, start: gap.lowerBound, end: gap.upperBound, asOf: demand.asOf
                ))
                guard uncovered.count <= ProviderDemandStore.maximumDemands else { throw ProviderFailure.capacityExceeded }
                start = gap.upperBound
            }
        }
        return try ProviderQueryCoverage(demands: uncovered, window: window)
    }

    private func firstGap(profile: String, window: Range<Date>, purpose: ProviderCheckpoint.Purpose) async throws -> Range<Date>? {
        // Window functions merge overlapping and nested ranges without loading the lifetime ledger into memory.
        let row = try await sql.raw("""
            WITH covered AS (
                SELECT CASE WHEN coverage.window_start < \(bind: window.lowerBound) THEN \(bind: window.lowerBound)
                            ELSE coverage.window_start END AS lower_bound,
                       CASE WHEN coverage.window_end > \(bind: window.upperBound) THEN \(bind: window.upperBound)
                            ELSE coverage.window_end END AS upper_bound
                FROM provider_query_coverage coverage JOIN provider_checkpoints checkpoint ON checkpoint.id = coverage.checkpoint_id
                JOIN provider_connections origin ON origin.id = checkpoint.connection_id
                JOIN provider_connections current_connection ON current_connection.id = \(bind: connectionID)
                WHERE checkpoint.source_token = \(bind: sourceToken) AND checkpoint.purpose = \(bind: purpose.rawValue)
                    AND coverage.profile = \(bind: profile) AND coverage.window_start < \(bind: window.upperBound)
                    AND coverage.window_end > \(bind: window.lowerBound)
                    AND origin.participant_id = current_connection.participant_id AND origin.source_id = current_connection.source_id
                    AND origin.account_pseudonym = current_connection.account_pseudonym
                    AND (checkpoint.status = 'complete' OR (origin.id = current_connection.id AND checkpoint.status = 'blocked'))
            ), ordered AS (
                SELECT lower_bound, upper_bound,
                    MAX(upper_bound) OVER (ORDER BY lower_bound, upper_bound ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prior_end
                FROM covered
            ), gaps AS (
                SELECT \(bind: window.lowerBound) AS gap_start, COALESCE(MIN(lower_bound), \(bind: window.upperBound)) AS gap_end
                FROM covered HAVING COUNT(*) = 0 OR MIN(lower_bound) > \(bind: window.lowerBound)
                UNION ALL SELECT prior_end, lower_bound FROM ordered WHERE prior_end < lower_bound
                UNION ALL SELECT MAX(upper_bound), \(bind: window.upperBound) FROM covered HAVING MAX(upper_bound) < \(bind: window.upperBound)
            ) SELECT gap_start, gap_end FROM gaps ORDER BY gap_start LIMIT 1
            """)
            .first()
        guard let row else {
            return nil
        }
        let start = try row.decode(column: "gap_start", as: Date.self), end = try row.decode(column: "gap_end", as: Date.self)
        guard window.lowerBound <= start, start < end, end <= window.upperBound else { throw ProviderFailure.unavailable }
        return start..<end
    }
}
