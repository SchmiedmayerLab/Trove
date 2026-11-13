//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import CTroveDeliverySQLite
import Foundation


extension DeliveryJournal {
    private static var querySelection: String { """
        SELECT acquisition_query.id, acquisition_query.local_id, definition, cursor, checkpoint_revision,
            (SELECT revision FROM collection_state WHERE id = 1), last_served, query_exhausted
        FROM acquisition_query JOIN source_state ON acquisition_query.local_id = source_state.local_id
        """ }

    /// The original query remains the default. Creating a backfill never resets its cursor.
    public func checkpoint(for sourceID: UUID) throws -> Checkpoint {
        let rows = try database.query("SELECT local_id FROM source_state WHERE source_id = ?", [.text(sourceID.uuidString.lowercased())]) {
            try Self.identifier($0, 0)
        }
        guard let localID = rows.first else { throw JournalError.unknownSource }
        return try checkpoint(for: sourceID, queryID: localID)
    }

    /// Restore a particular immutable query, even after revocation, without creating replacement state.
    public func checkpoint(for sourceID: UUID, queryID: UUID) throws -> Checkpoint {
        let rows = try database.query(
            Self.querySelection + " WHERE source_id = ? AND acquisition_query.id = ?",
            [.text(sourceID.uuidString.lowercased()), .text(queryID.uuidString.lowercased())]
        ) { try decodeCheckpoint($0, sourceID: sourceID) }
        guard let checkpoint = rows.first else { throw JournalError.unknownQuery }
        return checkpoint
    }

    /// All independent cursors share one source identity and delivery sequence, not another registration.
    public func checkpoints(for sourceID: UUID) throws -> [Checkpoint] {
        try Task.checkCancellation()
        _ = try checkpoint(for: sourceID)
        let rows = try database.query(
            Self.querySelection + " WHERE source_id = ? ORDER BY acquisition_query.id LIMIT ?",
            [.text(sourceID.uuidString.lowercased()), .integer(Int64(limits.maximumQueries) + 1)]
        ) { try decodeCheckpoint($0, sourceID: sourceID) }
        guard rows.count <= limits.maximumQueries else { throw JournalError.capacityExceeded }
        return rows
    }

    /// Explicitly create a bounded query once. Restore with checkpoints; duplicate IDs never replace state.
    public func createQuery(for sourceID: UUID, queryID: UUID, definition: Data) throws -> Checkpoint {
        try Task.checkCancellation()
        return try database.transaction {
            let source = try activeSource(sourceID)
            try insertQuery(id: queryID, localID: source.localID, definition: definition)
            try checkByteLimit()
            try Task.checkCancellation()
            return try checkpoint(for: sourceID, queryID: queryID)
        }
    }

    func insertQuery(id: UUID, localID: UUID, definition: Data) throws {
        guard (1...16_384).contains(definition.count) else { throw JournalError.invalidConfiguration }
        let existing = try database.query("SELECT id FROM acquisition_query WHERE id = ?", [.text(id.uuidString.lowercased())]) {
            try DeliverySQLite.text($0, 0)
        }
        guard existing.isEmpty else { throw JournalError.queryConflict }
        let counts = try database.query("SELECT count(*) FROM acquisition_query") { sqlite3_column_int64($0, 0) }
        guard let count = counts.first, count < limits.maximumQueries else { throw JournalError.capacityExceeded }
        try database.execute(
            "INSERT INTO acquisition_query(id, local_id, definition, checkpoint_revision) VALUES (?, ?, ?, ?)",
            [.text(id.uuidString.lowercased()), .text(localID.uuidString.lowercased()), .blob(definition), .text(UUID().uuidString.lowercased())]
        )
    }

    func lastQuerySequence(for sourceID: UUID) throws -> Int64 {
        let rows = try database.query(
            """
            SELECT coalesce(max(last_served), 0) FROM acquisition_query JOIN source_state
                ON acquisition_query.local_id = source_state.local_id WHERE source_id = ?
            """, [.text(sourceID.uuidString.lowercased())]
        ) { sqlite3_column_int64($0, 0) }
        guard let sequence = rows.first, sequence >= 0 else { throw JournalError.corruptJournal }
        return sequence
    }

    private func decodeCheckpoint(_ statement: OpaquePointer, sourceID: UUID) throws -> Checkpoint {
        guard (1...16_384).contains(sqlite3_column_bytes(statement, 2)),
              sqlite3_column_type(statement, 3) == SQLITE_NULL || (1...65_536).contains(sqlite3_column_bytes(statement, 3)),
              sqlite3_column_int64(statement, 6) >= 0, (0...1).contains(sqlite3_column_int64(statement, 7)) else {
            throw JournalError.corruptJournal
        }
        return Checkpoint(
            sourceID: sourceID,
            queryID: try Self.identifier(statement, 0),
            epoch: try Self.identifier(statement, 1),
            queryDefinition: try DeliverySQLite.blob(statement, 2),
            cursor: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : try DeliverySQLite.blob(statement, 3),
            lastServedSequence: sqlite3_column_int64(statement, 6),
            queryExhausted: sqlite3_column_int64(statement, 7) == 1,
            scope: scope,
            revision: try Self.identifier(statement, 4),
            collectionRevision: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : try Self.identifier(statement, 5)
        )
    }
}
