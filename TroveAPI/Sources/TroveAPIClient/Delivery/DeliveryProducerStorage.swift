//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract


extension DeliveryJournal {
    private struct ProducerStorage: ExchangeProducer.Storage {
        let url: URL
        let scope: Scope
        let sourceID: UUID
        let checkpointRevision: UUID
        let limits: Limits

        func transaction<Result>(_ body: (any ExchangeProducer.Transaction) throws -> Result) throws -> Result {
            try DeliveryJournalSchema.checkProtection(of: url.deletingLastPathComponent())
            try DeliveryJournalSchema.checkProtection(of: url)
            let database = try DeliverySQLite(url: url)
            defer { database.close() }
            try DeliveryJournalSchema.configure(
                database, scope: scope, contract: Contract.identifier, create: false, maximumBytes: limits.maximumDatabaseBytes
            )
            return try database.transaction {
                let bindings = try database.query(
                    "SELECT local_id, binding, checkpoint_revision FROM source_state WHERE source_id = ?", [.text(sourceID.uuidString.lowercased())]
                ) { statement in
                    (try DeliverySQLite.text(statement, 0), try DeliverySQLite.blob(statement, 1), try DeliverySQLite.text(statement, 2))
                }
                guard let (localID, bytes, revision) = bindings.first, let localID = UUID(uuidString: localID) else {
                    throw JournalError.unknownSource
                }
                let binding = try JSONDecoder().decode(Contract.SourceBinding.self, from: bytes)
                let source = try Contract.source(binding, localID: localID, scope: scope)
                guard source.id == sourceID, source.revokedAt == nil else { throw JournalError.sourceRevoked }
                guard revision == checkpointRevision.uuidString.lowercased() else { throw JournalError.staleCheckpoint }
                let transaction = ProducerTransaction(database: database, sourceID: sourceID.uuidString.lowercased())
                defer { transaction.isOpen = false }
                let result = try body(transaction)
                try DeliveryJournalSchema.checkByteLimit(database, maximumBytes: limits.maximumBytes)
                return result
            }
        }
    }
    private final class ProducerTransaction: ExchangeProducer.Transaction {
        let database: DeliverySQLite
        let sourceID: String
        var isOpen = true

        init(database: DeliverySQLite, sourceID: String) {
            self.database = database
            self.sourceID = sourceID
        }

        func read(_ key: String) throws -> Data? {
            try validate(key)
            return try database.query(
                "SELECT value FROM producer_ledger WHERE source_id = ? AND key = ?", [.text(sourceID), .text(key)]
            ) { try DeliverySQLite.blob($0, 0) }.first
        }

        func write(_ value: Data, for key: String) throws {
            try validate(key)
            guard (1...1_048_576).contains(value.count) else { throw DeliveryJournalError.invalidConfiguration }
            try database.execute(
                """
                INSERT INTO producer_ledger(source_id, key, value) VALUES (?, ?, ?)
                ON CONFLICT(source_id, key) DO UPDATE SET value = excluded.value
                """, [.text(sourceID), .text(key), .blob(value)]
            )
        }

        func remove(_ key: String) throws {
            try validate(key)
            try database.execute("DELETE FROM producer_ledger WHERE source_id = ? AND key = ?", [.text(sourceID), .text(key)])
        }

        func keys(prefixedBy prefix: String) throws -> [String] {
            try validate(prefix, allowsEmpty: true)
            return try database.query(
                "SELECT key FROM producer_ledger WHERE source_id = ? AND substr(key, 1, ?) = ? ORDER BY key",
                [.text(sourceID), .integer(Int64(prefix.utf8.count)), .text(prefix)]
            ) { try DeliverySQLite.text($0, 0) }
        }

        private func validate(_ key: String, allowsEmpty: Bool = false) throws {
            guard isOpen, (allowsEmpty ? 0...64 : 1...64).contains(key.utf8.count),
                  key.utf8.allSatisfy({ $0 > 0 && $0 < 128 }) else {
                throw DeliveryJournalError.invalidConfiguration
            }
        }
    }

    /// Grove's ledger belongs to one query checkpoint. Successful staging atomically retires it
    /// with the cursor; the next checkpoint receives a new producer instance. Failed staging and
    /// process restarts preserve the original ledger for byte-exact retries. Old handles cannot
    /// mutate a subsequent checkpoint. SQLite contention fails retriably without blocking a task.
    public func producerStorage(from expected: Checkpoint) throws -> some ExchangeProducer.Storage {
        _ = try activeSource(expected.sourceID)
        guard try checkpoint(for: expected.sourceID) == expected else { throw JournalError.staleCheckpoint }
        return ProducerStorage(url: url, scope: scope, sourceID: expected.sourceID, checkpointRevision: expected.revision, limits: limits)
    }
}
