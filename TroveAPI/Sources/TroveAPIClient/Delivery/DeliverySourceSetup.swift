//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import CTroveDeliverySQLite
import Foundation
import GroveFHIRContract


extension DeliveryJournal {
    /// Durable registration state, deliberately excluding privacy key material.
    public struct SourceSetup: Sendable, Equatable {
        public let localID: UUID
        public let queryDefinition: Data
        public let binding: Contract.SourceBinding?
        let scope: Scope

        /// Reuse this nonce for every registration attempt, including uncertain responses.
        public var registrationID: UUID { localID }
    }

    /// Explicitly creates a new stream before its first HTTP request. Never use creation as a restoration fallback.
    /// Restore existing streams with `sourceSetups()`; duplicate creation never replaces a key or query.
    public func createSource(localID: UUID, queryDefinition: Data) throws -> SourceSetup {
        try Task.checkCancellation()
        guard (1...16_384).contains(queryDefinition.count) else { throw JournalError.invalidConfiguration }
        return try database.transaction {
            let existing = try database.query("SELECT local_id FROM source_state WHERE local_id = ?", [.text(localID.uuidString.lowercased())]) {
                try DeliverySQLite.text($0, 0)
            }
            guard existing.isEmpty else { throw JournalError.sourceConflict }
            let count = try database.query("SELECT count(*) FROM source_state") { sqlite3_column_int64($0, 0) }
            guard let count = count.first, count < Self.maximumSources else { throw JournalError.capacityExceeded }
            let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try database.execute(
                """
                INSERT INTO source_state(local_id, privacy_key, query_definition, next_sequence, checkpoint_revision)
                VALUES (?, ?, ?, 1, ?)
                """,
                [.text(localID.uuidString.lowercased()), .blob(key), .blob(queryDefinition), .text(UUID().uuidString.lowercased())]
            )
            try checkByteLimit()
            try Task.checkCancellation()
            return try sourceSetup(for: localID)
        }
    }

    /// Restores setup without generating a key, changing the query, or creating a missing row.
    public func sourceSetup(for localID: UUID) throws -> SourceSetup {
        try Task.checkCancellation()
        let rows = try database.query(
            Self.sourceSetupSelection + " WHERE local_id = ?",
            [.text(localID.uuidString.lowercased())]
        ) { try Self.decodeSetup($0, scope: scope) }
        guard let row = rows.first else { throw JournalError.unknownSource }
        return row
    }

    /// Restores every pending, confirmed and revoked stream from one bounded database snapshot.
    /// Fails as a whole on corruption; never hides a stream or creates replacement state.
    public func sourceSetups() throws -> [SourceSetup] {
        try Task.checkCancellation()
        let rows = try database.query(
            Self.sourceSetupSelection + " ORDER BY local_id LIMIT ?", [.integer(Self.maximumSources + 1)]
        ) { statement in
            try Task.checkCancellation()
            return try Self.decodeSetup(statement, scope: scope)
        }
        guard rows.count <= Self.maximumSources else { throw JournalError.capacityExceeded }
        try Task.checkCancellation()
        return rows
    }

    /// Records a response from the caller's authenticated, scope-bound client. Does not establish authentication itself.
    /// Identity is immutable; the sole permitted update is permanent revocation. Stale replies cannot reactivate a source.
    @discardableResult
    public func confirmSource(_ binding: Contract.SourceBinding, for expected: SourceSetup) throws -> SourceSetup {
        try Task.checkCancellation()
        guard expected.scope == scope else { throw JournalError.wrongScope }
        let source = try Contract.source(binding, localID: expected.localID, scope: scope)
        return try database.transaction {
            let current = try sourceSetup(for: expected.localID)
            guard current.queryDefinition == expected.queryDefinition else { throw JournalError.sourceConflict }
            if let existing = current.binding {
                try Contract.validateUpdate(from: existing, to: binding)
            }
            let bytes = try JSONEncoder().encode(binding)
            guard bytes.count <= 16_384 else { throw JournalError.invalidSourceBinding }
            try database.execute(
                "UPDATE source_state SET source_id = ?, producer_system = ?, binding = ? WHERE local_id = ?",
                [.text(source.id.uuidString.lowercased()), .text(source.eventSystem), .blob(bytes), .text(expected.localID.uuidString.lowercased())]
            )
            try checkByteLimit()
            try Task.checkCancellation()
            return try sourceSetup(for: expected.localID)
        }
    }

    /// Restores the private Grove conversion scope only for a confirmed, non-revoked stream.
    /// One key epoch belongs to one stream; replacing a lost key requires an explicitly new source.
    public func identityScope(for sourceID: UUID) throws -> OpaqueIdentityScope {
        let setup = try activeSource(sourceID)
        guard let binding = setup.binding else { throw JournalError.corruptJournal }
        let keys = try database.query("SELECT privacy_key FROM source_state WHERE source_id = ?", [.text(sourceID.uuidString.lowercased())]) {
            try DeliverySQLite.blob($0, 0)
        }
        guard let key = keys.first, key.count == 32 else { throw JournalError.corruptJournal }
        return try .init(
            systems: Contract.source(binding, localID: setup.localID, scope: scope).systems,
            keyID: setup.localID.uuidString.lowercased(),
            epoch: EventSequence(1),
            key: SymmetricKey(data: key)
        )
    }
}


extension DeliveryJournal {
    func activeSource(_ sourceID: UUID) throws -> SourceSetup {
        try Task.checkCancellation()
        let rows = try database.query(
            Self.sourceSetupSelection + " WHERE source_id = ?", [.text(sourceID.uuidString.lowercased())]
        ) { try Self.decodeSetup($0, scope: scope) }
        guard let setup = rows.first else { throw JournalError.unknownSource }
        guard let binding = setup.binding else { throw JournalError.corruptJournal }
        guard try Contract.source(binding, localID: setup.localID, scope: scope).revokedAt == nil else { throw JournalError.sourceRevoked }
        return setup
    }
}


extension DeliveryJournal {
    private static var maximumSources: Int64 { 512 }
    private static var sourceSetupSelection: String { """
        SELECT local_id, query_definition, binding, source_id, producer_system, length(privacy_key), typeof(privacy_key)
        FROM source_state
        """ }

    private static func decodeSetup(_ statement: OpaquePointer, scope: Scope) throws -> SourceSetup {
        let rawID = try DeliverySQLite.text(statement, 0)
        guard let localID = UUID(uuidString: rawID), rawID == localID.uuidString.lowercased(),
              sqlite3_column_int64(statement, 5) == 32, try DeliverySQLite.text(statement, 6) == "blob",
              (1...16_384).contains(sqlite3_column_bytes(statement, 1)) else { throw JournalError.corruptJournal }
        let query = try DeliverySQLite.blob(statement, 1)
        var binding: Contract.SourceBinding?
        if sqlite3_column_type(statement, 2) != SQLITE_NULL {
            guard (1...16_384).contains(sqlite3_column_bytes(statement, 2)) else { throw JournalError.corruptJournal }
            do {
                let decoded = try JSONDecoder().decode(Contract.SourceBinding.self, from: DeliverySQLite.blob(statement, 2))
                let source = try Contract.source(decoded, localID: localID, scope: scope)
                guard source.id.uuidString.lowercased() == (try DeliverySQLite.text(statement, 3)),
                      source.eventSystem.utf8.elementsEqual(try DeliverySQLite.text(statement, 4).utf8) else { throw JournalError.corruptJournal }
                binding = decoded
            } catch {
                throw JournalError.corruptJournal
            }
        } else if sqlite3_column_type(statement, 3) != SQLITE_NULL || sqlite3_column_type(statement, 4) != SQLITE_NULL {
            throw JournalError.corruptJournal
        }
        return SourceSetup(localID: localID, queryDefinition: query, binding: binding, scope: scope)
    }
}
