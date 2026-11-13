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


/// One bounded value keeps complete discovery and irreversible local stops in the same transaction.
private struct RetainedCollectionContent: Codable, Sendable {
    var plans: [Components.Schemas.ParticipantCollectionPlan]
    var hasDiscoveredEnrollments: Bool
    var stoppedEnrollmentIDs: Set<UUID>

    func snapshot() throws -> ParticipantCollectionSnapshot? {
        guard stoppedEnrollmentIDs.count <= 4096 else { throw DeliveryJournalError.capacityExceeded }
        guard hasDiscoveredEnrollments else {
            guard plans.isEmpty else { throw DeliveryJournalError.corruptJournal }
            return nil
        }
        let ids = try plans.map { plan in
            guard let id = UUID(uuidString: plan.enrollmentId) else { throw ParticipantCollectionSnapshot.CollectionError.invalidPlan }
            return id
        }
        // Validate the complete stored value, including plans excluded by a local stop.
        _ = try ParticipantCollectionSnapshot(plans: plans, enrollmentIDs: ids)
        let eligible = zip(plans, ids).filter { !stoppedEnrollmentIDs.contains($0.1) }.map(\.0)
        let eligibleIDs = ids.filter { !stoppedEnrollmentIDs.contains($0) }
        return try ParticipantCollectionSnapshot(plans: eligible, enrollmentIDs: eligibleIDs)
    }
}


/// An account-bound local observation. Only the journal can create its revision token.
/// Nil snapshot means that no complete server discovery has been retained yet.
public struct ParticipantCollectionState: Sendable {
    public let snapshot: ParticipantCollectionSnapshot?
    public let stoppedEnrollmentIDs: Set<UUID>
    let scope: DeliveryScope
    let revision: UUID?
    fileprivate let content: RetainedCollectionContent
}


extension DeliveryJournal where Contract == TroveDeliveryContract {
    /// Restores accepted collection authority without consulting a clock, token endpoint or network.
    /// Account/backend scope is checked when opening the journal; upload authorization remains server-owned.
    public func collectionState() throws -> ParticipantCollectionState {
        let rows = try database.query("SELECT revision, content FROM collection_state WHERE id = 1") { statement in
            guard (1...4_194_304).contains(sqlite3_column_bytes(statement, 1)) else { throw JournalError.corruptJournal }
            do {
                let content = try JSONDecoder().decode(RetainedCollectionContent.self, from: DeliverySQLite.blob(statement, 1))
                return ParticipantCollectionState(
                    snapshot: try content.snapshot(),
                    stoppedEnrollmentIDs: content.stoppedEnrollmentIDs,
                    scope: scope,
                    revision: try Self.identifier(statement, 0),
                    content: content
                )
            } catch {
                throw JournalError.corruptJournal
            }
        }
        return rows.first ?? ParticipantCollectionState(
            snapshot: nil,
            stoppedEnrollmentIDs: [],
            scope: scope,
            revision: nil,
            content: RetainedCollectionContent(plans: [], hasDiscoveredEnrollments: false, stoppedEnrollmentIDs: [])
        )
    }

    /// Capture `expected` before fetching the complete enrollment set and every plan. A partial or failed
    /// discovery must not call this method. Late responses cannot undo a local stop or a newer refresh.
    @discardableResult
    public func retainCollectionSnapshot(
        _ snapshot: ParticipantCollectionSnapshot,
        replacing expected: ParticipantCollectionState
    ) throws -> ParticipantCollectionState {
        try Task.checkCancellation()
        guard expected.scope == scope else { throw JournalError.wrongScope }
        return try database.transaction {
            let current = try collectionState()
            guard current.revision == expected.revision else { throw JournalError.staleCollectionState }
            var content = current.content
            try validateCollectionSuccessor(snapshot.plans, previous: content.plans)
            let incoming = Set(snapshot.plans.compactMap { UUID(uuidString: $0.enrollmentId) })
            for previous in content.plans {
                guard let id = UUID(uuidString: previous.enrollmentId) else { throw JournalError.corruptJournal }
                // Disappearance from a complete server discovery must not revive on a later response.
                if !incoming.contains(id) { content.stoppedEnrollmentIDs.insert(id) }
                if !previous.windows.isEmpty,
                   snapshot.plans.contains(where: { UUID(uuidString: $0.enrollmentId) == id && $0.windows.isEmpty }) {
                    content.stoppedEnrollmentIDs.insert(id)
                }
            }
            content.plans = snapshot.plans
            content.hasDiscoveredEnrollments = true
            try storeCollectionContent(content)
            try Task.checkCancellation()
            return try collectionState()
        }
    }

    /// Persist before attempting withdrawal over the network. A failed request does not restart collection.
    /// This does not delete queued data, change its consent IDs, or claim that server withdrawal succeeded.
    @discardableResult
    public func stopCollection(for enrollmentID: UUID) throws -> ParticipantCollectionState {
        try stopCollection(for: [enrollmentID], replacing: nil)
    }

    /// A refresh uses compare-and-swap so recording known stops cannot mask an intervening adoption.
    func stopCollection(for enrollmentIDs: Set<UUID>, replacing expected: ParticipantCollectionState?) throws -> ParticipantCollectionState {
        try Task.checkCancellation()
        if let expected, expected.scope != scope { throw JournalError.wrongScope }
        return try database.transaction {
            let current = try collectionState()
            if let expected, current.revision != expected.revision { throw JournalError.staleCollectionState }
            var content = current.content
            let stopped = content.stoppedEnrollmentIDs.union(enrollmentIDs)
            guard stopped != content.stoppedEnrollmentIDs else {
                return current
            }
            content.stoppedEnrollmentIDs = stopped
            try storeCollectionContent(content)
            try Task.checkCancellation()
            return try collectionState()
        }
    }

    /// Bind a query to the retained authority used for filtering its outputs. `stage` compares this
    /// checkpoint inside its transaction, so another connection's withdrawal also invalidates the pass.
    public func collectionCheckpoint(
        for sourceID: UUID,
        state: ParticipantCollectionState,
        queryID: UUID? = nil
    ) throws -> Checkpoint {
        guard state.scope == scope else { throw JournalError.wrongScope }
        guard state.snapshot != nil else { throw ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized }
        let checkpoint = try queryID.map { try self.checkpoint(for: sourceID, queryID: $0) } ?? self.checkpoint(for: sourceID)
        guard checkpoint.collectionRevision == state.revision else { throw JournalError.staleCollectionState }
        return checkpoint
    }

    private func storeCollectionContent(_ content: RetainedCollectionContent) throws {
        _ = try content.snapshot()
        let bytes = try JSONEncoder().encode(content)
        guard bytes.count <= 4_194_304 else { throw JournalError.capacityExceeded }
        try database.execute(
            """
            INSERT INTO collection_state(id, revision, content) VALUES (1, ?, ?)
            ON CONFLICT(id) DO UPDATE SET revision = excluded.revision, content = excluded.content
            """, [.text(UUID().uuidString.lowercased()), .blob(bytes)]
        )
        try checkByteLimit()
    }

    private func validateCollectionSuccessor(
        _ incoming: [Components.Schemas.ParticipantCollectionPlan], previous: [Components.Schemas.ParticipantCollectionPlan]
    ) throws {
        for old in previous {
            guard let next = incoming.first(where: { UUID(uuidString: $0.enrollmentId) == UUID(uuidString: old.enrollmentId) }) else { continue }
            guard next.stateVersion >= old.stateVersion, next.asOf >= old.asOf,
                  next.stateVersion != old.stateVersion || next.windows == old.windows else { throw JournalError.staleCollectionState }
        }
    }
}
