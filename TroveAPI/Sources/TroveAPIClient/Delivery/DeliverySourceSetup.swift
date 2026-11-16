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
            let credential = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try database.execute(
                """
                INSERT INTO source_state(local_id, installation_credential, query_definition, next_sequence, checkpoint_revision)
                VALUES (?, ?, ?, 1, ?)
                """,
                [.text(localID.uuidString.lowercased()), .blob(credential), .blob(queryDefinition), .text(UUID().uuidString.lowercased())]
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
    public func confirmSource(_ binding: Contract.SourceBinding, for expected: SourceSetup, identityKey: Data? = nil) throws -> SourceSetup {
        try Task.checkCancellation()
        guard expected.scope == scope else { throw JournalError.wrongScope }
        let source = try Contract.source(binding, localID: expected.localID, scope: scope)
        return try database.transaction {
            let current = try sourceSetup(for: expected.localID)
            guard current.queryDefinition == expected.queryDefinition else { throw JournalError.sourceConflict }
            if let existing = current.binding {
                try Contract.validateUpdate(from: existing, to: binding)
            }
            let retainedKeys = try database.query(
                "SELECT privacy_key FROM source_state WHERE local_id = ?", [.text(expected.localID.uuidString.lowercased())]
            ) { sqlite3_column_type($0, 0) == SQLITE_NULL ? nil : try DeliverySQLite.blob($0, 0) }
            let retainedKey = retainedKeys.compactMap { $0 }.first
            guard identityKey.map({ $0.count == 32 }) ?? true,
                  retainedKey == nil || identityKey == nil || retainedKey == identityKey,
                  source.revokedAt != nil || retainedKey != nil || identityKey != nil else { throw JournalError.sourceConflict }
            let bytes = try JSONEncoder().encode(binding)
            guard bytes.count <= 16_384 else { throw JournalError.invalidSourceBinding }
            try database.execute(
                "UPDATE source_state SET source_id = ?, producer_system = ?, binding = ?, privacy_key = coalesce(privacy_key, ?) WHERE local_id = ?",
                [
                    .text(source.id.uuidString.lowercased()), .text(source.eventSystem), .blob(bytes),
                    identityKey.map(DeliverySQLite.Value.blob) ?? .null, .text(expected.localID.uuidString.lowercased())
                ]
            )
            if source.revokedAt != nil {
                // No future query may use this checkpoint. Retain custody payloads and receipts,
                // but release auxiliary deletion bounds that can no longer be staged.
                try database.execute("DELETE FROM deletion_detection WHERE source_id = ?", [.text(source.id.uuidString.lowercased())])
            }
            try checkByteLimit()
            try Task.checkCancellation()
            return try sourceSetup(for: expected.localID)
        }
    }

    /// Installation proof is stored before the first registration request and excluded from public setup state.
    public func installationCredential(for localID: UUID) throws -> Data {
        try Task.checkCancellation()
        let values = try database.query(
            "SELECT installation_credential FROM source_state WHERE local_id = ?", [.text(localID.uuidString.lowercased())]
        ) {
            try DeliverySQLite.blob($0, 0)
        }
        guard let credential = values.first else { throw JournalError.unknownSource }
        guard credential.count == 32 else { throw JournalError.corruptJournal }
        return credential
    }

    /// Restores the private Grove conversion scope only for a confirmed, non-revoked stream.
    /// A recovered server identity is immutable even when the local installation changes.
    public func identityScope(for sourceID: UUID) throws -> OpaqueIdentityScope {
        let setup = try activeSource(sourceID)
        guard let binding = setup.binding else { throw JournalError.corruptJournal }
        let keys = try database.query("SELECT privacy_key FROM source_state WHERE source_id = ?", [.text(sourceID.uuidString.lowercased())]) {
            try DeliverySQLite.blob($0, 0)
        }
        guard let key = keys.first, key.count == 32 else { throw JournalError.corruptJournal }
        let source = try Contract.source(binding, localID: setup.localID, scope: scope)
        return try .init(
            systems: source.systems,
            keyID: source.identity.keyID,
            epoch: source.identity.epoch,
            key: SymmetricKey(data: key)
        )
    }
}


extension DeliveryJournal {
    func activeDeliverySource(_ sourceID: UUID) throws -> DeliverySource {
        let setup = try activeSource(sourceID)
        guard let binding = setup.binding else { throw JournalError.corruptJournal }
        return try Contract.source(binding, localID: setup.localID, scope: scope)
    }

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
        SELECT local_id, query_definition, binding, source_id, producer_system, length(privacy_key), typeof(privacy_key),
            length(installation_credential), typeof(installation_credential)
        FROM source_state
        """ }

    private static func decodeSetup(_ statement: OpaquePointer, scope: Scope) throws -> SourceSetup {
        let rawID = try DeliverySQLite.text(statement, 0)
        let keyType = try DeliverySQLite.text(statement, 6)
        guard let localID = UUID(uuidString: rawID), rawID == localID.uuidString.lowercased(),
              sqlite3_column_int64(statement, 7) == 32, try DeliverySQLite.text(statement, 8) == "blob",
              keyType == "null" || (sqlite3_column_int64(statement, 5) == 32 && keyType == "blob"),
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
                guard source.revokedAt != nil || sqlite3_column_int64(statement, 5) == 32 else { throw JournalError.corruptJournal }
                binding = decoded
            } catch {
                throw JournalError.corruptJournal
            }
        } else if sqlite3_column_type(statement, 3) != SQLITE_NULL || sqlite3_column_type(statement, 4) != SQLITE_NULL
            || sqlite3_column_type(statement, 5) != SQLITE_NULL {
            throw JournalError.corruptJournal
        }
        return SourceSetup(localID: localID, queryDefinition: query, binding: binding, scope: scope)
    }
}
