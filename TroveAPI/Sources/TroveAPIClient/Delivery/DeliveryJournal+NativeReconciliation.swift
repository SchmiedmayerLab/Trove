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


extension DeliveryJournal where Contract == TroveDeliveryContract {
    public struct ReconciliationSelection: Sendable {
        public let authority: NativeCollectionReconciliation
        public let checkpoint: Checkpoint
        public let snapshot: ParticipantCollectionSnapshot
    }

    public struct ReconciliationCompletion: Sendable {
        public let id: UUID
        public let enrollmentID: UUID
    }

    /// A current complete plan response must already be retained. A late lease response cannot undo a local stop.
    public func retainNativeReconciliations(
        _ instructions: [Components.Schemas.NativeCollectionReconciliationInstruction],
        for sourceID: UUID,
        replacing expected: ParticipantCollectionState,
        at now: Date = .now
    ) throws {
        try Task.checkCancellation()
        guard expected.scope == scope, instructions.count <= 256,
              Set(instructions.map(\.id)).count == instructions.count else { throw JournalError.invalidConfiguration }
        try database.transaction {
            let state = try collectionState()
            guard state.revision == expected.revision, let snapshot = state.snapshot else { throw JournalError.staleCollectionState }
            let source = try activeSource(sourceID)
            for instruction in instructions {
                guard let plan = snapshot.plans.first(where: { $0.enrollmentId == instruction.enrollmentId }) else {
                    throw ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized
                }
                let authority = try NativeCollectionReconciliation(instruction, plan: plan, sourceID: sourceID, at: now)
                try retainNativeReconciliation(authority, plan: plan, localID: source.localID)
            }
            try checkByteLimit()
            try Task.checkCancellation()
        }
    }

    private func retainNativeReconciliation(
        _ authority: NativeCollectionReconciliation, plan: Components.Schemas.ParticipantCollectionPlan, localID: UUID
    ) throws {
        if let previous = try reconciliationInstruction(authority.id) {
            let old = try NativeCollectionReconciliation(previous, plan: plan, sourceID: authority.sourceID, at: previous.issuedAt)
            guard authority.renews(old) else { throw JournalError.staleCollectionState }
            let checkpoint = try checkpoint(for: authority.sourceID, queryID: authority.id)
            guard try checkpoint.queryDefinition == authority.definition.encoded() else { throw JournalError.corruptJournal }
        } else {
            try insertQuery(id: authority.id, localID: localID, definition: authority.definition.encoded())
        }
        let bytes = try JSONEncoder().encode(authority.instruction)
        guard bytes.count <= 16_384 else { throw JournalError.capacityExceeded }
        try database.execute("""
            INSERT INTO native_collection_reconciliation(id, instruction, server_acknowledged) VALUES (?, ?, 0)
            ON CONFLICT(id) DO UPDATE SET instruction = excluded.instruction
            """, [.text(authority.id.uuidString.lowercased()), .blob(bytes)])
    }

    /// This is the only native acquisition path that can use an ended enrollment, under its separate current lease.
    public func nativeReconciliationSelection(
        id: UUID, sourceID: UUID, state expected: ParticipantCollectionState, at now: Date = .now
    ) throws -> ReconciliationSelection {
        guard expected.scope == scope else { throw JournalError.wrongScope }
        return try database.transaction {
            let state = try collectionState()
            guard state.revision == expected.revision, let snapshot = state.snapshot else { throw JournalError.staleCollectionState }
            _ = try activeSource(sourceID)
            guard let value = try reconciliationInstruction(id),
                  let plan = snapshot.plans.first(where: { $0.enrollmentId == value.enrollmentId }) else {
                throw ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized
            }
            let authority = try NativeCollectionReconciliation(value, plan: plan, sourceID: sourceID, at: now)
            var checkpoint = try checkpoint(for: sourceID, queryID: id)
            guard !checkpoint.queryExhausted, checkpoint.collectionRevision == state.revision,
                  try checkpoint.queryDefinition == authority.definition.encoded() else { throw JournalError.staleCheckpoint }
            checkpoint.acquisitionDeadline = authority.expiresAt
            return try ReconciliationSelection(authority: authority, checkpoint: checkpoint, snapshot: snapshot.reconciling(authority))
        }
    }

    private func reconciliationInstruction(_ id: UUID) throws -> Components.Schemas.NativeCollectionReconciliationInstruction? {
        let rows = try database.query(
            "SELECT instruction FROM native_collection_reconciliation WHERE id = ?", [.text(id.uuidString.lowercased())]
        ) { statement in
            guard (1...16_384).contains(sqlite3_column_bytes(statement, 0)) else { throw JournalError.corruptJournal }
            return try JSONDecoder().decode(
                Components.Schemas.NativeCollectionReconciliationInstruction.self, from: DeliverySQLite.blob(statement, 0)
            )
        }
        return rows.first
    }

    /// Ordinary catch-up must never reinterpret or restart these instruction-owned historical queries.
    func nativeReconciliationQueryIDs(for sourceID: UUID) throws -> Set<UUID> {
        let rows = try database.query("""
            SELECT native_collection_reconciliation.id FROM native_collection_reconciliation
            JOIN acquisition_query ON acquisition_query.id = native_collection_reconciliation.id
            JOIN source_state ON source_state.local_id = acquisition_query.local_id WHERE source_state.source_id = ?
            """, [.text(sourceID.uuidString.lowercased())]) { try Self.identifier($0, 0) }
        guard rows.count <= limits.maximumQueries else { throw JournalError.capacityExceeded }
        return Set(rows)
    }

    /// Local empty-page receipts awaiting an idempotent server completion acknowledgement.
    public func completedNativeReconciliations(for sourceID: UUID) throws -> [ReconciliationCompletion] {
        try checkpoints(for: sourceID).filter {
            $0.queryExhausted && $0.lastServedSequence > 0
        }
        .compactMap { checkpoint in
            let rows = try database.query(
                "SELECT server_acknowledged FROM native_collection_reconciliation WHERE id = ?",
                [.text(checkpoint.queryID.uuidString.lowercased())]
            ) { sqlite3_column_int64($0, 0) }
            guard rows == [0], let instruction = try reconciliationInstruction(checkpoint.queryID),
                  let enrollmentID = UUID(uuidString: instruction.enrollmentId) else { return nil }
            return ReconciliationCompletion(id: checkpoint.queryID, enrollmentID: enrollmentID)
        }
    }

    /// Retain the server acknowledgement without deleting the completed query or its immutable instruction.
    public func acknowledgeNativeReconciliation(_ id: UUID, sourceID: UUID) throws {
        try database.transaction {
            let checkpoint = try checkpoint(for: sourceID, queryID: id)
            guard checkpoint.queryExhausted, checkpoint.lastServedSequence > 0,
                  try reconciliationInstruction(id) != nil else { throw JournalError.staleCheckpoint }
            try database.execute(
                "UPDATE native_collection_reconciliation SET server_acknowledged = 1 WHERE id = ?", [.text(id.uuidString.lowercased())]
            )
            try Task.checkCancellation()
        }
    }
}
