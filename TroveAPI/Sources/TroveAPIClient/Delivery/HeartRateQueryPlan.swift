//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import CTroveDeliverySQLite
import Foundation


/// One durable sweep revisits every eligible predicate for late imports and explicit deletions.
/// Exhaustion applies only to this sweep; it never permanently completes a historical query.
public struct HeartRateQueryPlan: Sendable {
    public struct Query: Sendable {
        public let checkpoint: EventDeliveryJournal.Checkpoint
        public let definition: HeartRateQueryDefinition

        init(_ checkpoint: EventDeliveryJournal.Checkpoint) throws {
            self.checkpoint = checkpoint
            definition = try HeartRateQueryDefinition(bytes: checkpoint.queryDefinition)
        }
    }

    public let queries: [Query]
    let sourceID: UUID
    let sweepStart: Int64
    let scope: DeliveryScope
    let collectionRevision: UUID?

    /// Reserve one page per pass for this query before processing the oldest pending historical work.
    public var liveQuery: Query? { queries.first { $0.definition.kind == .live } }

    public var pendingQueries: [Query] {
        queries.filter { $0.checkpoint.lastServedSequence <= sweepStart || !$0.checkpoint.queryExhausted }.sorted {
            if $0.checkpoint.lastServedSequence != $1.checkpoint.lastServedSequence {
                return $0.checkpoint.lastServedSequence < $1.checkpoint.lastServedSequence
            }
            return $0.checkpoint.queryID.uuidString < $1.checkpoint.queryID.uuidString
        }
    }
}


extension DeliveryJournal where Contract == TroveDeliveryContract {
    /// Add only newly eligible historical gaps. Consent reconciliation and new predicates commit together;
    /// capacity failure cannot mark a gap covered without creating its independent query.
    public func heartRateQueryPlan(
        for sourceID: UUID, state: ParticipantCollectionState, at now: Date = .now
    ) throws -> HeartRateQueryPlan {
        try Task.checkCancellation()
        guard HeartRateQueryDefinition.validDate(now) else { throw JournalError.invalidConfiguration }
        return try database.transaction {
            let primary = try collectionCheckpoint(for: sourceID, state: state)
            _ = try activeSource(sourceID)
            guard let snapshot = state.snapshot, snapshot.permitsHeartRateAcquisition else {
                throw ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized
            }
            let existing = try checkpoints(for: sourceID).map(HeartRateQueryPlan.Query.init)
            let live = try HeartRateQueryDefinition(bytes: primary.queryDefinition)
            guard live.kind == .live, existing.filter({ $0.definition.kind == .live }).count == 1 else {
                throw JournalError.corruptJournal
            }
            let stored = try queryPlanningState(for: sourceID)
            let coverage = HeartRateQueryCoverage(snapshot: snapshot, reconciled: stored.consents)
            let firstSetup = !stored.hasReconciled && existing.allSatisfy { $0.checkpoint.cursor == nil }
            let cutoff = firstSetup ? live.start : max(live.start, now)
            let gaps = coverage.missing(before: cutoff, queries: existing.map(\.definition))
            for gap in gaps {
                let definition = try HeartRateQueryDefinition(kind: .historical, start: gap.lowerBound, end: gap.upperBound)
                try insertQuery(id: UUID(), localID: primary.epoch, definition: definition.encoded())
            }
            let changed = !stored.hasReconciled || stored.consents != coverage.consentIDs || !gaps.isEmpty
            let sweep = try (!changed ? stored.sweep : nil) ?? lastQuerySequence(for: sourceID)
            if changed || stored.sweep == nil {
                try storeQueryPlanningState(for: sourceID, consents: coverage.consentIDs, sweep: sweep)
            }
            try checkByteLimit()
            let queries = try checkpoints(for: sourceID).map(HeartRateQueryPlan.Query.init).filter { coverage.includes($0.definition) }
            try Task.checkCancellation()
            return HeartRateQueryPlan(
                queries: queries, sourceID: sourceID, sweepStart: sweep, scope: scope, collectionRevision: state.revision
            )
        }
    }

    /// A concurrent refresh, withdrawal or new sweep cannot be completed by a stale caller.
    public func finishHeartRateQuerySweep(_ plan: HeartRateQueryPlan, state: ParticipantCollectionState) throws -> Bool {
        try Task.checkCancellation()
        guard plan.scope == scope else { throw JournalError.wrongScope }
        guard plan.collectionRevision == state.revision else { throw JournalError.staleCollectionState }
        return try database.transaction {
            _ = try collectionCheckpoint(for: plan.sourceID, state: state)
            _ = try activeSource(plan.sourceID)
            let stored = try queryPlanningState(for: plan.sourceID)
            guard stored.sweep == plan.sweepStart else { throw JournalError.staleCheckpoint }
            let current = try checkpoints(for: plan.sourceID)
            guard let snapshot = state.snapshot else { throw JournalError.staleCollectionState }
            let coverage = HeartRateQueryCoverage(snapshot: snapshot, reconciled: stored.consents)
            let activeIDs = try Set(current.map(HeartRateQueryPlan.Query.init).filter { coverage.includes($0.definition) }.map {
                $0.checkpoint.queryID
            })
            guard current.filter({ activeIDs.contains($0.queryID) }).allSatisfy({
                $0.lastServedSequence > plan.sweepStart && $0.queryExhausted
            }) else { return false }
            try database.execute(
                "UPDATE source_state SET query_sweep_start = NULL WHERE source_id = ?", [.text(plan.sourceID.uuidString.lowercased())]
            )
            try Task.checkCancellation()
            return true
        }
    }
}


extension DeliveryJournal where Contract == TroveDeliveryContract {
    private struct QueryPlanningState {
        let consents: Set<UUID>
        let hasReconciled: Bool
        let sweep: Int64?
    }

    private func queryPlanningState(for sourceID: UUID) throws -> QueryPlanningState {
        let rows = try database.query(
            "SELECT collection_consents, query_sweep_start FROM source_state WHERE source_id = ?", [.text(sourceID.uuidString.lowercased())]
        ) { statement in
            let sweep = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 1)
            guard sweep.map({ $0 >= 0 }) ?? true else { throw JournalError.corruptJournal }
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL else {
                return QueryPlanningState(consents: [], hasReconciled: false, sweep: sweep)
            }
            guard (1...8_388_608).contains(sqlite3_column_bytes(statement, 0)) else { throw JournalError.corruptJournal }
            do {
                let ids = try JSONDecoder().decode([UUID].self, from: DeliverySQLite.blob(statement, 0))
                guard ids.count <= 131_072, Set(ids).count == ids.count else { throw JournalError.corruptJournal }
                return QueryPlanningState(consents: Set(ids), hasReconciled: true, sweep: sweep)
            } catch {
                throw JournalError.corruptJournal
            }
        }
        guard let stored = rows.first else { throw JournalError.unknownSource }
        return stored
    }

    private func storeQueryPlanningState(for sourceID: UUID, consents: Set<UUID>, sweep: Int64) throws {
        let bytes = try JSONEncoder().encode(consents.sorted { $0.uuidString < $1.uuidString })
        try database.execute(
            "UPDATE source_state SET collection_consents = ?, query_sweep_start = ? WHERE source_id = ?",
            [.blob(bytes), .integer(sweep), .text(sourceID.uuidString.lowercased())]
        )
    }
}
