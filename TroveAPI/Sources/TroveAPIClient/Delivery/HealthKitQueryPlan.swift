//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import CTroveDeliverySQLite
import Foundation
import TroveAPITypes


/// One durable sweep revisits every eligible predicate for late imports and explicit deletions.
/// Exhaustion applies only to this sweep; it never permanently completes a historical query.
public struct HealthKitQueryPlan: Sendable {
    public enum Mode: Sendable, Equatable { case collection, retractionsOnly }

    public struct Query: Sendable {
        public let checkpoint: EventDeliveryJournal.Checkpoint
        public let definition: HealthKitQueryDefinition
        public let mode: Mode

        init(_ checkpoint: EventDeliveryJournal.Checkpoint, mode: Mode = .collection) throws {
            self.checkpoint = checkpoint
            self.mode = mode
            definition = try HealthKitQueryDefinition(bytes: checkpoint.queryDefinition)
        }
    }

    public let queries: [Query]
    let sourceID: UUID
    let sweepStart: Int64
    let scope: DeliveryScope
    let collectionRevision: UUID?
    let acquisitionDeadline: Date?

    /// Reserve one page per pass for each live measurement before processing pending historical work.
    public var liveQueries: [Query] { queries.filter { $0.definition.kind == .live && $0.mode == .collection } }

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
    public func healthKitQueryPlan(
        for sourceID: UUID, state: ParticipantCollectionState, at now: Date = .now
    ) throws -> HealthKitQueryPlan {
        try Task.checkCancellation()
        guard HealthKitQueryDefinition.validDate(now) else { throw JournalError.invalidConfiguration }
        return try database.transaction {
            let primary = try collectionCheckpoint(for: sourceID, state: state, at: now)
            _ = try activeSource(sourceID)
            guard let snapshot = try state.snapshot?.active(at: now), !snapshot.retainedStreams.isEmpty else {
                throw ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized
            }
            let existing = try validatedQueries(for: sourceID, primary: primary)
            let stored = try queryPlanningState(for: sourceID)
            let coverage = snapshot.acquisitionStreams.map { HealthKitQueryCoverage(stream: $0, snapshot: snapshot, reconciled: stored.consents) }
            let firstSetup = !stored.hasReconciled && existing.allSatisfy { $0.checkpoint.cursor == nil }
            var addedQueries = false
            for measurement in coverage {
                addedQueries = try reconcileQueries(
                    measurement, existing: existing, localID: primary.epoch, firstSetup: firstSetup, at: now
                ) || addedQueries
            }
            let consents = Set(coverage.flatMap(\.consentIDs))
            let changed = !stored.hasReconciled || stored.consents != consents || addedQueries
            let sweep = try (!changed ? stored.sweep : nil) ?? lastQuerySequence(for: sourceID)
            if changed || stored.sweep == nil {
                try storeQueryPlanningState(for: sourceID, consents: consents, sweep: sweep)
            }
            try checkByteLimit()
            let queries = try collectionQueries(for: sourceID, coverage: coverage, snapshot: snapshot)
            try Task.checkCancellation()
            return HealthKitQueryPlan(
                queries: queries,
                sourceID: sourceID,
                sweepStart: sweep,
                scope: scope,
                collectionRevision: state.revision,
                acquisitionDeadline: snapshot.acquisitionDeadline
            )
        }
    }

    private func collectionQueries(
        for sourceID: UUID, coverage: [HealthKitQueryCoverage], snapshot: ParticipantCollectionSnapshot
    ) throws -> [HealthKitQueryPlan.Query] {
        try checkpoints(for: sourceID).compactMap { value in
            var checkpoint = value
            checkpoint.acquisitionDeadline = snapshot.acquisitionDeadline
            let query = try HealthKitQueryPlan.Query(checkpoint)
            if coverage.contains(where: { $0.includes(query.definition) }) {
                return query
            }
            guard !snapshot.permitsAcquisition(stream: query.definition.stream),
                  snapshot.permitsRetractions(stream: query.definition.stream), checkpoint.cursor != nil else {
                return nil
            }
            return try HealthKitQueryPlan.Query(checkpoint, mode: .retractionsOnly)
        }
    }

    /// A concurrent refresh, withdrawal or new sweep cannot be completed by a stale caller.
    public func finishHealthKitQuerySweep(
        _ plan: HealthKitQueryPlan, state: ParticipantCollectionState, at now: Date = .now, reviewDocuments: Bool = false
    ) throws -> Bool {
        try Task.checkCancellation()
        guard plan.scope == scope else { throw JournalError.wrongScope }
        guard plan.collectionRevision == state.revision, plan.acquisitionDeadline.map({ now < $0 }) ?? true else {
            throw JournalError.staleCollectionState
        }
        return try database.transaction {
            _ = try collectionCheckpoint(for: plan.sourceID, state: state, at: now)
            _ = try activeSource(plan.sourceID)
            let stored = try queryPlanningState(for: plan.sourceID)
            guard stored.sweep == plan.sweepStart else { throw JournalError.staleCheckpoint }
            let current = try checkpoints(for: plan.sourceID)
            guard let snapshot = try state.snapshot?.active(at: now) else { throw JournalError.staleCollectionState }
            let coverage = snapshot.acquisitionStreams.map { HealthKitQueryCoverage(stream: $0, snapshot: snapshot, reconciled: stored.consents) }
            let activeIDs = try Set(collectionQueries(for: plan.sourceID, coverage: coverage, snapshot: snapshot)
                .filter { ($0.definition.stream.timeBasis == .cdaSourceDocumentPeriod) == reviewDocuments }
                .map { $0.checkpoint.queryID })
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


    private func validatedQueries(for sourceID: UUID, primary: Checkpoint) throws -> [HealthKitQueryPlan.Query] {
        let existing = try checkpoints(for: sourceID).map { try HealthKitQueryPlan.Query($0) }
        let lives = existing.filter { $0.definition.kind == .live }
        let groups = Dictionary(grouping: lives, by: \.definition.stream)
        guard try HealthKitQueryDefinition(bytes: primary.queryDefinition).kind == .live,
              groups.values.allSatisfy({ Set($0.map { $0.definition.version }).count == $0.count }) else { throw JournalError.corruptJournal }
        return existing
    }

    private func reconcileQueries(
        _ coverage: HealthKitQueryCoverage,
        existing: [HealthKitQueryPlan.Query],
        localID: UUID,
        firstSetup: Bool,
        at now: Date
    ) throws -> Bool {
        let previous = existing.first {
            $0.definition.hasCurrentSemantics && $0.definition.stream == coverage.stream && $0.definition.kind == .live
        }
        let live: HealthKitQueryDefinition
        if let previous {
            live = previous.definition
        } else {
            guard let earliest = coverage.ranges.first?.lowerBound else {
                return false
            }
            live = try HealthKitQueryDefinition(stream: coverage.stream, kind: .live, start: max(earliest, now))
            try insertQuery(id: UUID(), localID: localID, definition: live.encoded())
        }
        let cutoff = firstSetup ? live.start : max(live.start, now)
        let gaps = coverage.missing(before: cutoff, queries: existing.map(\.definition))
        for gap in gaps {
            let definition = try HealthKitQueryDefinition(
                stream: coverage.stream, kind: .historical, start: gap.lowerBound, end: gap.upperBound
            )
            try insertQuery(id: UUID(), localID: localID, definition: definition.encoded())
        }
        return previous == nil || !gaps.isEmpty
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
