//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import CTroveDeliverySQLite
import Foundation


/// Account-scoped query-checkpoint, staging and custody transactions. Does not perform queries or networking.
public actor DeliveryJournal<Contract: DeliveryContract> {
    /// Immutable account and backend binding.
    public typealias Scope = DeliveryScope

    /// Journal state, protection and capacity failures.
    public typealias JournalError = DeliveryJournalError

    public struct Limits: Sendable {
        public var maximumBytes: Int
        public var maximumEvents: Int
        public var maximumDatabaseBytes: Int

        public init(
            maximumBytes: Int = 64 * 1024 * 1024,
            maximumEvents: Int = 2048,
            maximumDatabaseBytes: Int = 128 * 1024 * 1024
        ) {
            self.maximumBytes = maximumBytes
            self.maximumEvents = maximumEvents
            self.maximumDatabaseBytes = maximumDatabaseBytes
        }
    }

    public struct Payload: Sendable {
        public let bytes: Data
        public let targets: [Contract.Target]

        public init(bytes: Data, targets: [Contract.Target]) {
            self.bytes = bytes
            self.targets = targets
        }
    }

    /// A snapshot for exactly one registered query. Only the journal constructs checkpoints.
    public struct Checkpoint: Sendable, Equatable {
        public let sourceID: UUID
        public let epoch: UUID
        public let queryDefinition: Data
        public let cursor: Data?
        let scope: Scope
        let revision: UUID
    }

    public struct Attempt: Sendable {
        public let deliveryID: UUID
        public let bytes: Data
        public let commitment: Contract.Commitment
        public let custodyWasUncertain: Bool
        public let attemptCount: Int
    }

    public enum BlockReason: Codable, Sendable, Equatable {
        case rejected(statusCode: Int)
        case invalidReceipt
    }

    public enum DeliveryStatus: Sendable, Equatable {
        case pending
        case waiting(until: Date)
        case blocked(BlockReason)
        case delivered
    }

    public enum OpenMode: Sendable {
        case createNew
        case openExisting
    }

    let database: DeliverySQLite
    let limits: Limits
    let url: URL
    /// Immutable principal/backend binding used when constructing the authenticated drain.
    nonisolated public let scope: Scope

    /// The caller supplies an owner-only (0700) application directory. Existing files must be owner-only (0600).
    /// Missing established journals are never recreated; unsafe permissions are never silently repaired.
    public init(url: URL, scope: Scope, mode: OpenMode, limits: Limits = .init()) throws {
        guard url.isFileURL, !url.path.utf8.contains(0),
              [Contract.identifier, scope.backend, scope.issuer, scope.subject].allSatisfy({ (1...2048).contains($0.utf8.count) }),
              (1...512 * 1024 * 1024).contains(limits.maximumBytes),
              (1...65_536).contains(limits.maximumEvents),
              (65_536...1024 * 1024 * 1024).contains(limits.maximumDatabaseBytes) else {
            throw JournalError.invalidConfiguration
        }
        let url = try DeliverySQLite.databaseURL(url)
        try DeliveryJournalSchema.checkProtection(of: url.deletingLastPathComponent())
        if mode == .createNew {
            // Exclusive creation; SQLite's OPEN_EXCLUSIVE flag does not provide this guarantee.
            #if os(iOS) || os(watchOS) || os(visionOS)
            try Data().write(to: url, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try Data().write(to: url, options: .withoutOverwriting)
            #endif
            // The new file is still empty. Restrict access before SQLite writes any identity or event bytes.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        try DeliveryJournalSchema.checkProtection(of: url)
        let database = try DeliverySQLite(url: url)
        try DeliveryJournalSchema.configure(
            database, scope: scope, contract: Contract.identifier, create: mode == .createNew, maximumBytes: limits.maximumDatabaseBytes
        )
        self.database = database
        self.url = url
        self.limits = limits
        self.scope = scope
    }

    /// Releases the connection; later operations fail instead of reopening implicitly.
    public func close() {
        database.close()
    }

    /// Read this checkpoint before a bounded query; query semantics must match its immutable definition.
    public func checkpoint(for sourceID: UUID) throws -> Checkpoint {
        let rows = try database.query(
            "SELECT local_id, query_definition, cursor, checkpoint_revision FROM source_state WHERE source_id = ?", [.text(sourceID.lowercase)]
        ) { statement in
            Checkpoint(
                sourceID: sourceID,
                epoch: try Self.identifier(statement, 0),
                queryDefinition: try DeliverySQLite.blob(statement, 1),
                cursor: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : try DeliverySQLite.blob(statement, 2),
                scope: scope,
                revision: try Self.identifier(statement, 3)
            )
        }
        guard let checkpoint = rows.first else { throw JournalError.unknownSource }
        return checkpoint
    }

    /// Commit prepared payloads and their next cursor together. Grove owns wire identities;
    /// the queue sequence only orders local deliveries. Conversion must visit every change:
    /// omit explicit policy exclusions, but never advance past a malformed or refused record.
    /// A stale checkpoint requires reloading and querying again, never transforming the old result under a newer cursor.
    public func stage(
        from expected: Checkpoint,
        nextCursor: Data,
        payloads: [Payload],
        observedDeletions: [UUID] = []
    ) throws -> [UUID] {
        try Task.checkCancellation()
        guard expected.scope == scope else { throw JournalError.wrongScope }
        guard (1...65_536).contains(nextCursor.count), payloads.count <= 128,
              observedDeletions.count <= 128 else { throw JournalError.invalidConfiguration }
        return try database.transaction {
            let registered = try activeDeliverySource(expected.sourceID)
            guard try checkpoint(for: expected.sourceID) == expected else { throw JournalError.staleCheckpoint }
            let source = try database.query(
                "SELECT next_sequence, producer_system FROM source_state WHERE source_id = ?", [.text(expected.sourceID.lowercase)]
            ) {
                (sqlite3_column_int64($0, 0), try DeliverySQLite.text($0, 1))
            }
            guard let (sequence, system) = source.first else { throw JournalError.unknownSource }
            let deliveryIDs = try stagePayloads(payloads, source: registered, sequence: sequence, system: system)
            try retireDeletionDetections(observedDeletions, sourceID: expected.sourceID)
            // Retire the conversion instant only after record bytes and the cursor are durable.
            try database.execute("DELETE FROM producer_ledger WHERE source_id = ?", [.text(expected.sourceID.lowercase)])
            try database.execute(
                "UPDATE source_state SET cursor = ?, checkpoint_revision = ? WHERE source_id = ?",
                [.blob(nextCursor), .text(UUID().lowercase), .text(expected.sourceID.lowercase)]
            )
            try checkByteLimit()
            try Task.checkCancellation()
            return deliveryIDs
        }
    }

    private func retireDeletionDetections(_ recordIDs: [UUID], sourceID: UUID) throws {
        for id in recordIDs {
            try database.execute(
                "DELETE FROM deletion_detection WHERE source_id = ? AND record_id = ?", [.text(sourceID.lowercase), .text(id.lowercase)]
            )
        }
    }

    /// Marks an attempt before any network request. Repeated preparation requires uncertain-custody recovery.
    public func prepareAttempt(_ id: UUID, at now: Date = .now) throws -> Attempt? {
        try Task.checkCancellation()
        guard now.timeIntervalSince1970.isFinite else { throw JournalError.invalidConfiguration }
        return try database.transaction {
            let status = try status(for: id)
            switch status {
            case .delivered, .blocked:
                return nil
            case .waiting(let deadline) where deadline > now:
                return nil
            default: break
            }
            let attempt = try loadAttempt(id)
            try database.execute("UPDATE delivery SET attempt_count = min(attempt_count + 1, 1000000) WHERE id = ?", [.text(id.lowercase)])
            return attempt
        }
    }

    /// Receipt persistence and payload removal share one transaction. The query cursor was committed with the payload.
    public func recordReceipt(_ receipt: Contract.Receipt, for id: UUID) throws {
        try database.transaction {
            if let existing = try storedReceipt(id) {
                guard existing == receipt else { throw JournalError.receiptConflict }
                return
            }
            try Contract.verify(receipt, against: Contract.metadata(for: loadAttempt(id).commitment))
            let bytes = try JSONEncoder().encode(receipt)
            try database.execute(
                "UPDATE delivery SET receipt = ?, payload = NULL, blocked = NULL, retry_after = 0 WHERE id = ?", [.blob(bytes), .text(id.lowercase)]
            )
        }
    }

    /// Returns retained custody evidence, including after reopening and payload removal.
    public func receipt(for id: UUID) throws -> Contract.Receipt? {
        try storedReceipt(id)
    }

    /// Returns a bounded list without loading event payloads into memory.
    public func pendingDeliveryIDs(limit: Int = 16) throws -> [UUID] {
        guard (1...128).contains(limit) else { throw JournalError.invalidConfiguration }
        return try database.query("SELECT id FROM delivery WHERE receipt IS NULL ORDER BY rowid LIMIT ?", [.integer(Int64(limit))]) {
            try Self.identifier($0, 0)
        }
    }
}


extension DeliveryJournal {
    /// Deletes only verified delivered rows. Query checkpoints and producer sequences are never reset.
    /// After pruning, callers must use server history rather than this bounded delivery queue for old receipts.
    @discardableResult
    public func pruneDelivered(limit: Int = 128) throws -> Int {
        guard (1...128).contains(limit) else { throw JournalError.invalidConfiguration }
        return try database.transaction {
            let ids = try database.query("SELECT id FROM delivery WHERE receipt IS NOT NULL ORDER BY rowid LIMIT ?", [.integer(Int64(limit))]) {
                try Self.identifier($0, 0)
            }
            for id in ids {
                guard try storedReceipt(id) != nil else { throw JournalError.corruptJournal }
                try database.execute("DELETE FROM delivery WHERE id = ?", [.text(id.lowercase)])
            }
            return ids.count
        }
    }

    /// Selects ready events in insertion order; blocked work cannot starve a later source.
    public func readyDeliveryIDs(at now: Date, limit: Int = 16) throws -> [UUID] {
        guard (1...128).contains(limit), now.timeIntervalSince1970.isFinite else { throw JournalError.invalidConfiguration }
        return try database.query(
            "SELECT id FROM delivery WHERE receipt IS NULL AND blocked IS NULL AND retry_after <= ? ORDER BY rowid LIMIT ?",
            [.real(now.timeIntervalSince1970), .integer(Int64(limit))]
        ) { try Self.identifier($0, 0) }
    }

    /// Reports durable state without exposing payloads or server error messages.
    public func status(for id: UUID) throws -> DeliveryStatus {
        if try storedReceipt(id) != nil {
            return .delivered
        }
        let states = try database.query("SELECT blocked, retry_after FROM delivery WHERE id = ?", [.text(id.lowercase)]) { statement in
            if sqlite3_column_type(statement, 0) != SQLITE_NULL {
                let reason = try JSONDecoder().decode(BlockReason.self, from: DeliverySQLite.blob(statement, 0))
                return DeliveryStatus.blocked(reason)
            }
            let deadline = sqlite3_column_double(statement, 1)
            guard deadline.isFinite else { throw JournalError.corruptJournal }
            return deadline == 0 ? .pending : .waiting(until: Date(timeIntervalSince1970: deadline))
        }
        guard let state = states.first else { throw JournalError.unknownDelivery }
        return state
    }

    /// Preserves retry timing across process launches without a background task or timer.
    public func deferRetry(_ id: UUID, until deadline: Date) throws {
        guard (0...253_402_300_799).contains(deadline.timeIntervalSince1970) else { throw JournalError.invalidConfiguration }
        try database.transaction {
            _ = try storedReceipt(id)
            try database.execute(
                "UPDATE delivery SET retry_after = ? WHERE id = ? AND receipt IS NULL AND blocked IS NULL",
                [.real(deadline.timeIntervalSince1970), .text(id.lowercase)]
            )
        }
    }

    /// Stops automatic retries while retaining original bytes and a bounded, non-sensitive reason.
    public func block(_ id: UUID, reason: BlockReason) throws {
        if case .rejected(let code) = reason, !(100...599).contains(code) { throw JournalError.invalidConfiguration }
        let bytes = try JSONEncoder().encode(reason)
        try database.transaction {
            _ = try storedReceipt(id)
            try database.execute(
                "UPDATE delivery SET blocked = ?, retry_after = 0 WHERE id = ? AND receipt IS NULL", [.blob(bytes), .text(id.lowercase)]
            )
        }
    }
}


extension DeliveryJournal {
    private func stagePayloads(_ payloads: [Payload], source: DeliverySource, sequence: Int64, system: String) throws -> [UUID] {
        var deliveryIDs: [UUID] = []
        var nextSequence = sequence
        for payload in payloads {
            try Task.checkCancellation()
            let commitment = try Contract.commitment(sourceID: source.id, originalBytes: payload.bytes, targets: payload.targets)
            let metadata = Contract.metadata(for: commitment)
            guard metadata.sourceID == source.id,
                  metadata.eventSystem.utf8.elementsEqual(system.utf8)
                    || metadata.eventSystem.utf8.elementsEqual(source.systems.recordRetraction.rawValue.utf8) else {
                throw JournalError.eventIdentityMismatch
            }
            if let existing = try existingDelivery(payload: payload, commitment: commitment) {
                deliveryIDs.append(existing)
                continue
            }
            guard nextSequence < Int64.max else { throw JournalError.sequenceExhausted }
            let id = UUID()
            try insert(id: id, sequence: nextSequence, payload: payload, commitment: commitment)
            nextSequence += 1
            try checkByteLimit()
            deliveryIDs.append(id)
        }
        return deliveryIDs
    }

    /// Exact commitments reuse their pending or delivered row; distinct representations retain separate custody.
    private func existingDelivery(payload: Payload, commitment: Contract.Commitment) throws -> UUID? {
        let metadata = Contract.metadata(for: commitment)
        let rows = try database.query(
            """
            SELECT id, payload, targets, node_count FROM delivery
            WHERE source_id = ? AND event_system = ? AND event_value = ? AND payload_digest = ? AND target_digest = ?
            """,
            [
                .text(metadata.sourceID.lowercase), .text(metadata.eventSystem), .text(metadata.eventValue),
                .text(metadata.payloadSHA256), .text(metadata.targetSHA256)
            ]
        ) { statement in
            guard try DeliverySQLite.blob(statement, 2) == Contract.serializedTargets(for: commitment),
                  sqlite3_column_int64(statement, 3) == Int64(metadata.nodeCount) else { throw JournalError.corruptJournal }
            if sqlite3_column_type(statement, 1) != SQLITE_NULL {
                guard try DeliverySQLite.blob(statement, 1) == payload.bytes else { throw JournalError.eventIdentityMismatch }
            }
            return try Self.identifier(statement, 0)
        }
        guard let id = rows.first else {
            return nil
        }
        _ = try storedReceipt(id)
        return id
    }

    private func insert(
        id: UUID, sequence: Int64, payload: Payload, commitment: Contract.Commitment
    ) throws {
        let metadata = Contract.metadata(for: commitment)
        let sourceID = metadata.sourceID
        let intent = Contract.serializedTargets(for: commitment)
        let count = try database.query("SELECT count(*) FROM delivery") { sqlite3_column_int64($0, 0) }
        guard let count = count.first, count < limits.maximumEvents else { throw JournalError.capacityExceeded }
        try database.execute(
            """
            INSERT INTO delivery(id, source_id, sequence, event_system, event_value, payload, targets, payload_digest, target_digest, node_count)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(id.lowercase), .text(sourceID.lowercase), .integer(sequence), .text(metadata.eventSystem), .text(metadata.eventValue),
                .blob(payload.bytes), .blob(intent),
                .text(metadata.payloadSHA256), .text(metadata.targetSHA256), .integer(Int64(metadata.nodeCount))
            ]
        )
        try database.execute("UPDATE source_state SET next_sequence = ? WHERE source_id = ?", [.integer(sequence + 1), .text(sourceID.lowercase)])
    }

    func checkByteLimit() throws {
        try DeliveryJournalSchema.checkByteLimit(database, maximumBytes: limits.maximumBytes)
    }

    private func storedReceipt(_ id: UUID) throws -> Contract.Receipt? {
        let rows = try database.query(
            """
            SELECT d.receipt, d.source_id, d.event_system, d.event_value, d.payload_digest, d.target_digest, d.node_count
            FROM delivery d JOIN source_state s ON s.source_id = d.source_id WHERE d.id = ?
            """, [.text(id.lowercase)]
        ) { statement in
            if sqlite3_column_type(statement, 0) == SQLITE_NULL {
                return Optional<Contract.Receipt>.none
            }
            let receipt = try JSONDecoder().decode(Contract.Receipt.self, from: DeliverySQLite.blob(statement, 0))
            let sourceID = try Self.identifier(statement, 1)
            let system = try DeliverySQLite.text(statement, 2)
            let metadata = DeliveryCommitment(
                sourceID: sourceID,
                eventSystem: system,
                eventValue: try DeliverySQLite.text(statement, 3),
                payloadSHA256: try DeliverySQLite.text(statement, 4),
                targetSHA256: try DeliverySQLite.text(statement, 5),
                nodeCount: Int(sqlite3_column_int64(statement, 6))
            )
            do {
                try Contract.verify(receipt, against: metadata)
            } catch {
                throw JournalError.corruptJournal
            }
            return receipt
        }
        guard let row = rows.first else { throw JournalError.unknownDelivery }
        return row
    }

    private func loadAttempt(_ id: UUID) throws -> Attempt {
        let rows = try database.query(
            """
            SELECT d.source_id, d.payload, d.targets, d.payload_digest, d.target_digest,
                d.node_count, d.attempt_count, d.event_value, d.event_system
            FROM delivery d JOIN source_state s ON s.source_id = d.source_id WHERE d.id = ?
            """,
            [.text(id.lowercase)]
        ) { statement in
            let bytes = try DeliverySQLite.blob(statement, 1)
            let targets = try JSONDecoder().decode([Contract.Target].self, from: DeliverySQLite.blob(statement, 2))
            let sourceID = try Self.identifier(statement, 0)
            let commitment = try Contract.commitment(sourceID: sourceID, originalBytes: bytes, targets: targets)
            let system = try DeliverySQLite.text(statement, 8)
            let expected = DeliveryCommitment(
                sourceID: sourceID,
                eventSystem: system,
                eventValue: try DeliverySQLite.text(statement, 7),
                payloadSHA256: try DeliverySQLite.text(statement, 3),
                targetSHA256: try DeliverySQLite.text(statement, 4),
                nodeCount: Int(sqlite3_column_int64(statement, 5))
            )
            guard Contract.metadata(for: commitment) == expected else { throw JournalError.corruptJournal }
            let previousAttempts = Int(sqlite3_column_int64(statement, 6))
            return Attempt(
                deliveryID: id,
                bytes: bytes,
                commitment: commitment,
                custodyWasUncertain: previousAttempts > 0,
                attemptCount: min(previousAttempts + 1, 1_000_000)
            )
        }
        guard let row = rows.first else { throw JournalError.unknownDelivery }
        return row
    }
}


extension DeliveryJournal {
    private static func identifier(_ statement: OpaquePointer, _ column: Int32) throws -> UUID {
        guard let value = UUID(uuidString: try DeliverySQLite.text(statement, column)) else { throw JournalError.corruptJournal }
        return value
    }
}


extension UUID {
    fileprivate var lowercase: String { uuidString.lowercased() }
}
