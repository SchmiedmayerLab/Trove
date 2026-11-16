//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SQLKit


struct ProviderCheckpointStore {
    let connectionID: UUID
    let sourceToken: String
    let sql: any SQLDatabase
    let staged: ProviderCheckpoint?

    init(connectionID: UUID, sourceToken: String, sql: any SQLDatabase) async throws {
        self.connectionID = connectionID
        self.sourceToken = sourceToken
        self.sql = sql
        let row = try await sql.raw("""
            SELECT * FROM provider_checkpoints WHERE connection_id = \(bind: connectionID) AND source_token = \(bind: sourceToken)
                AND status = 'staged' ORDER BY window_start, window_end LIMIT 1
            """)
            .first()
        staged = try row.map(ProviderCheckpoint.init(row:))
    }

    func remainingWindow(demands: [ProviderDemand], purpose: ProviderCheckpoint.Purpose) async throws -> Range<Date>? {
        try await ProviderCoverageStore(connectionID: connectionID, sourceToken: sourceToken, sql: sql).next(demands: demands, purpose: purpose)
    }

    func hasPending(purpose: ProviderCheckpoint.Purpose) async throws -> Bool {
        let row = try await sql.raw("""
            SELECT id FROM provider_checkpoints WHERE connection_id = \(bind: connectionID) AND source_token = \(bind: sourceToken)
                AND purpose = \(bind: purpose.rawValue) AND status IN ('ready', 'fetching') LIMIT 1
            """)
            .first()
        return row != nil
    }

    func next(demands: [ProviderDemand], purpose: ProviderCheckpoint.Purpose, now: Date) async throws -> ProviderCheckpoint? {
        guard !demands.isEmpty else {
            return nil
        }
        if let pending = try await pending(demands: demands, purpose: purpose) {
            return pending
        }
        let store = ProviderCoverageStore(connectionID: connectionID, sourceToken: sourceToken, sql: sql)
        guard let window = try await store.next(demands: demands, purpose: purpose) else {
            return nil
        }
        let id = UUID()
        let coverage = try await store.selection(demands: demands, window: window, purpose: purpose)
        try await sql.raw("""
            INSERT INTO provider_checkpoints (
                id, connection_id, source_token, purpose, query_as_of, failure_count,
                window_start, window_end, query_coverage, coverage_digest, generation, status, page_complete, page_sequence, excluded_rows
            ) VALUES (
                \(bind: id), \(bind: connectionID), \(bind: sourceToken), \(bind: purpose.rawValue), \(bind: now), 0,
                \(bind: window.lowerBound), \(bind: window.upperBound), \(bind: try coverage.encoded), \(bind: try coverage.digest), 1, 'ready', \(bind: false), 1, 0
            )
            """)
            .run()
        for selected in coverage.selections {
            let selectedWindow = try selected.window
            try await sql.raw("""
                INSERT INTO provider_query_coverage (id, checkpoint_id, profile, window_start, window_end) VALUES (
                    \(bind: UUID()), \(bind: id), \(bind: selected.profile), \(bind: selectedWindow.lowerBound), \(bind: selectedWindow.upperBound)
                )
                """)
                .run()
        }
        guard let row = try await sql.raw("SELECT * FROM provider_checkpoints WHERE id = \(bind: id)").first() else {
            throw ProviderFailure.unavailable
        }
        return try .init(row: row)
    }

    private func pending(demands: [ProviderDemand], purpose: ProviderCheckpoint.Purpose) async throws -> ProviderCheckpoint? {
        for demand in demands {
            if let row = try await sql.raw("""
                SELECT checkpoint.* FROM provider_checkpoints checkpoint WHERE connection_id = \(bind: connectionID)
                    AND source_token = \(bind: sourceToken) AND purpose = \(bind: purpose.rawValue) AND status IN ('ready', 'fetching')
                    AND EXISTS (SELECT 1 FROM provider_query_coverage coverage WHERE coverage.checkpoint_id = checkpoint.id
                        AND coverage.profile = \(bind: demand.profile) AND coverage.window_start < \(bind: demand.end)
                        AND coverage.window_end > \(bind: demand.start))
                ORDER BY window_start, window_end LIMIT 1
                """)
                .first() { return try .init(row: row) }
        }
        return nil
    }
}
