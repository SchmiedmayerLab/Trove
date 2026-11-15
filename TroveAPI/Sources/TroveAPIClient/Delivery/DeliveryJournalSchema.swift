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


#if canImport(Darwin)
import Darwin


#elseif canImport(Glibc)
import Glibc


#endif


enum DeliveryJournalSchema {
    private struct Identity: Encodable {
        let scope: DeliveryScope
        let contract: String
    }

    static let maximumPayloadBytes = EventSubmissionLimits.maximumEventBytes
    /// An empty journal of the current format occupies 33 pages of 4 KiB (132 KiB). A smaller budget cannot hold
    /// the schema, so it is rejected as configuration and not left to fail inside SQLite.
    static let minimumDatabaseBytes = 136 * 1024
    private static let version: Int64 = 20

    static func checkByteLimit(_ database: DeliverySQLite, maximumBytes: Int) throws {
        let sizes = try database.query("""
            SELECT
                (SELECT coalesce(sum(coalesce(length(payload), 0) + length(targets)), 0) FROM delivery)
                + (SELECT coalesce(sum(coalesce(length(privacy_key), 0)
                    + length(installation_credential) + coalesce(length(binding), 0)
                    + coalesce(length(collection_consents), 0)), 0) FROM source_state)
                + (SELECT coalesce(sum(length(definition) + coalesce(length(cursor), 0)
                    + coalesce(length(conversion_instant), 0)), 0) FROM acquisition_query)
                + (SELECT count(*) * 80 FROM deletion_detection)
                + (SELECT count(*) * 144 FROM healthkit_record_conversion)
                + (SELECT coalesce(sum(length(content)), 0) FROM collection_state)
                + (SELECT coalesce(sum(256 + length(relative_path)), 0) FROM recording_file)
                + (SELECT coalesce(sum(length(declaration) + 64 + coalesce(length(registration), 0) + coalesce(length(receipt), 0)), 0)
                    FROM recording_transfer)
                + (SELECT coalesce(sum(length(content) + length(source_type_identifier) + length(device_product_type)
                    + length(coordinate) + 192), 0) FROM sensorkit_batch_evidence)
                + (SELECT count(*) * 96 FROM sensorkit_recording_slice)
                + (SELECT coalesce(sum(length(instruction) + 80), 0) FROM native_collection_reconciliation)
            """) { sqlite3_column_int64($0, 0) }
        guard let size = sizes.first, size <= maximumBytes else { throw DeliveryJournalError.capacityExceeded }
    }

    /// Journal sidecars inherit the private containing directory's protection and backup exclusion.
    static func checkProtection(of url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let isDirectory = attributes[.type] as? FileAttributeType == .typeDirectory
        let isFile = attributes[.type] as? FileAttributeType == .typeRegular
        guard isDirectory || isFile,
              attributes[.ownerAccountID] as? Int == Int(geteuid()),
              attributes[.posixPermissions] as? Int == (isDirectory ? 0o700 : 0o600),
              isDirectory || attributes[.referenceCount] as? Int == 1 else {
            throw DeliveryJournalError.unsafeStorage
        }
        #if canImport(Darwin)
        // Extended ACLs can grant access beyond mode bits. Inspect presence directly:
        // acl_get_link_np reports ENOENT for both absent ACLs and missing paths.
        guard let security = filesec_init() else { throw DeliveryJournalError.unsafeStorage }
        defer { filesec_free(security) }
        var metadata = stat()
        var present: Int32 = 1
        guard url.path.withCString({ lstatx_np($0, &metadata, security) }) == 0,
              filesec_query_property(security, FILESEC_ACL, &present) == 0, present == 0 else {
            throw DeliveryJournalError.unsafeStorage
        }
        #endif
        #if os(iOS) || os(watchOS) || os(visionOS)
        #if !targetEnvironment(simulator)
        // Simulator storage uses the host filesystem and does not report iOS protection classes.
        // Device builds must verify protection; simulator tests cannot establish this guarantee.
        guard attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication else {
            throw DeliveryJournalError.invalidConfiguration
        }
        #endif
        let directory = isDirectory ? url : url.deletingLastPathComponent()
        guard try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
            throw DeliveryJournalError.invalidConfiguration
        }
        #endif
    }

    static func configure(
        _ database: DeliverySQLite, scope: DeliveryScope, contract: String, create: Bool, limits: (databaseBytes: Int, contentBytes: Int)
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let scopeBytes = try encoder.encode(Identity(scope: scope, contract: contract))
        let priorVersion = try create ? Self.version : validateExisting(database, scopeBytes: scopeBytes)
        let journalMode = try database.query("PRAGMA journal_mode = DELETE") { try DeliverySQLite.text($0, 0) }
        guard journalMode == ["delete"] else { throw DeliveryJournalError.invalidConfiguration }
        try database.execute("PRAGMA synchronous = EXTRA")
        try database.execute("PRAGMA foreign_keys = ON")
        try database.execute("PRAGMA secure_delete = ON")
        try database.execute("PRAGMA temp_store = MEMORY")
        #if canImport(Darwin)
        try database.execute("PRAGMA fullfsync = ON")
        guard try database.query("PRAGMA fullfsync", read: { sqlite3_column_int64($0, 0) }) == [1] else {
            throw DeliveryJournalError.invalidConfiguration
        }
        #endif
        guard try database.query("PRAGMA synchronous", read: { sqlite3_column_int64($0, 0) }) == [3],
              try database.query("PRAGMA foreign_keys", read: { sqlite3_column_int64($0, 0) }) == [1] else {
            throw DeliveryJournalError.invalidConfiguration
        }
        guard let pageSize = try database.query("PRAGMA page_size", read: { sqlite3_column_int64($0, 0) }).first, pageSize > 0 else {
            throw DeliveryJournalError.corruptJournal
        }
        let maximumPages = Int64(limits.databaseBytes) / pageSize
        // Only a checked integer derived from configuration is interpolated into this pragma.
        let acceptedPages = try database.query("PRAGMA max_page_count = \(maximumPages)") { sqlite3_column_int64($0, 0) }
        guard acceptedPages == [maximumPages] else { throw DeliveryJournalError.capacityExceeded }
        try initializeStorage(database, scopeBytes: scopeBytes, create: create, priorVersion: priorVersion, maximumBytes: limits.contentBytes)
    }

    private static func initializeStorage(
        _ database: DeliverySQLite, scopeBytes: Data, create: Bool, priorVersion: Int64, maximumBytes: Int
    ) throws {
        if create {
            try database.transaction {
                for statement in statements + upgrades.flatMap(\.statements) { try database.execute(statement) }
                try database.execute("INSERT INTO journal_identity(id, scope) VALUES (1, ?)", [.blob(scopeBytes)])
                try database.execute("PRAGMA user_version = \(Self.version)")
            }
        } else if priorVersion < Self.version {
            // This additive migration leaves every queued payload, source binding, receipt and cursor intact.
            // Scope was verified before any pragma or schema mutation; SQLite rolls back all DDL on failure.
            try database.transaction {
                for upgrade in upgrades where priorVersion < upgrade.version {
                    for statement in upgrade.statements { try database.execute(statement) }
                }
                try checkByteLimit(database, maximumBytes: maximumBytes)
                try database.execute("PRAGMA user_version = \(Self.version)")
            }
        }
    }

    private static func validateExisting(_ database: DeliverySQLite, scopeBytes: Data) throws -> Int64 {
        let storedVersion = try database.query("PRAGMA user_version") { sqlite3_column_int64($0, 0) }
        guard storedVersion.count == 1, let prior = storedVersion.first, (17...Self.version).contains(prior) else {
            throw DeliveryJournalError.unsupportedFormat
        }
        let stored = try database.query("SELECT scope FROM journal_identity WHERE id = 1") { try DeliverySQLite.blob($0, 0) }
        guard stored == [scopeBytes] else { throw DeliveryJournalError.wrongScope }
        return prior
    }
}


extension DeliveryJournalSchema {
    /// Additive tables in the order their formats introduced them; a new journal creates all of them.
    private static let upgrades: [(version: Int64, statements: [String])] = [
        (18, replayStatements), (19, sliceStatements), (20, reconciliationStatements)
    ]

    private static let reconciliationStatements = [
        """
        CREATE TABLE native_collection_reconciliation (
            id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36) REFERENCES acquisition_query(id) ON DELETE RESTRICT,
            instruction BLOB NOT NULL CHECK (length(instruction) BETWEEN 1 AND 16384),
            server_acknowledged INTEGER NOT NULL DEFAULT 0 CHECK (server_acknowledged IN (0, 1))
        ) STRICT
        """
    ]

    private static let sliceStatements = [
        """
        CREATE TABLE sensorkit_recording_slice (
            batch_id INTEGER NOT NULL REFERENCES sensorkit_batch_evidence(id),
            row_start INTEGER NOT NULL CHECK (row_start >= 0),
            row_end INTEGER NOT NULL CHECK (row_end > row_start AND row_end <= 2147483647),
            source_record_id TEXT NOT NULL CHECK (length(source_record_id) = 36),
            sha256 BLOB NOT NULL CHECK (length(sha256) = 32),
            PRIMARY KEY(batch_id, row_start),
            UNIQUE(source_record_id)
        ) STRICT
        """
    ]

    private static let replayStatements = [
        """
        CREATE TABLE sensorkit_batch_evidence (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source_id TEXT NOT NULL REFERENCES source_state(source_id),
            source_type_identifier TEXT NOT NULL CHECK (length(source_type_identifier) BETWEEN 1 AND 512),
            device_product_type TEXT NOT NULL CHECK (length(device_product_type) BETWEEN 1 AND 256),
            coordinate TEXT NOT NULL CHECK (length(coordinate) BETWEEN 1 AND 1024),
            effective_start REAL NOT NULL,
            effective_end REAL NOT NULL CHECK (effective_end >= effective_start),
            content BLOB NOT NULL CHECK (length(content) BETWEEN 1 AND 131072),
            sha256 TEXT NOT NULL CHECK (length(sha256) = 64),
            staged_authority TEXT CHECK (staged_authority IS NULL OR length(staged_authority) = 64),
            UNIQUE (source_id, source_type_identifier, device_product_type, coordinate)
        ) STRICT
        """,
        "CREATE INDEX sensorkit_evidence_window ON sensorkit_batch_evidence(source_id, source_type_identifier, effective_start, effective_end)"
    ]

    private static let statements = [
        """
        CREATE TABLE collection_state (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            revision TEXT NOT NULL CHECK (length(revision) = 36),
            content BLOB NOT NULL CHECK (length(content) BETWEEN 1 AND 4194304)
        ) STRICT
        """,
        "CREATE TABLE journal_identity (id INTEGER PRIMARY KEY CHECK (id = 1), scope BLOB NOT NULL) STRICT",
        """
        CREATE TABLE source_state (
            local_id TEXT PRIMARY KEY NOT NULL CHECK (length(local_id) = 36),
            source_id TEXT UNIQUE,
            producer_system TEXT,
            privacy_key BLOB CHECK (privacy_key IS NULL OR length(privacy_key) = 32),
            installation_credential BLOB NOT NULL CHECK (length(installation_credential) = 32),
            binding BLOB CHECK (binding IS NULL OR length(binding) BETWEEN 1 AND 16384),
            next_sequence INTEGER NOT NULL CHECK (next_sequence > 0),
            collection_consents BLOB CHECK (collection_consents IS NULL OR length(collection_consents) BETWEEN 1 AND 8388608),
            query_sweep_start INTEGER CHECK (query_sweep_start IS NULL OR query_sweep_start >= 0),
            CHECK ((source_id IS NULL AND producer_system IS NULL AND binding IS NULL AND next_sequence = 1)
                OR (source_id IS NOT NULL AND length(source_id) = 36 AND producer_system IS NOT NULL
                    AND length(producer_system) BETWEEN 1 AND 512 AND binding IS NOT NULL))
        ) STRICT
        """,
        """
        CREATE TABLE delivery (
            id TEXT PRIMARY KEY NOT NULL,
            source_id TEXT NOT NULL REFERENCES source_state(source_id),
            sequence INTEGER NOT NULL CHECK (sequence > 0),
            event_system TEXT NOT NULL CHECK (length(event_system) BETWEEN 1 AND 512),
            event_value TEXT NOT NULL CHECK (length(event_value) BETWEEN 1 AND 512),
            payload BLOB,
            targets BLOB NOT NULL CHECK (length(targets) BETWEEN 1 AND 524288),
            payload_digest TEXT NOT NULL CHECK (length(payload_digest) = 64),
            target_digest TEXT NOT NULL CHECK (length(target_digest) = 64),
            node_count INTEGER NOT NULL CHECK (node_count BETWEEN 1 AND 512),
            attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count BETWEEN 0 AND 1000000),
            retry_after REAL NOT NULL DEFAULT 0 CHECK (retry_after BETWEEN 0 AND 253402300799),
            blocked BLOB CHECK (blocked IS NULL OR length(blocked) BETWEEN 1 AND 128),
            receipt BLOB CHECK (receipt IS NULL OR length(receipt) BETWEEN 1 AND 8192),
            UNIQUE (source_id, sequence),
            UNIQUE (source_id, event_system, event_value, payload_digest, target_digest),
            CHECK ((payload IS NOT NULL AND length(payload) BETWEEN 1 AND \(maximumPayloadBytes) AND receipt IS NULL)
                OR (payload IS NULL AND receipt IS NOT NULL AND blocked IS NULL AND retry_after = 0))
        ) STRICT
        """,
        """
        CREATE TABLE recording_file (
            id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
            source_id TEXT NOT NULL REFERENCES source_state(source_id),
            delivery_id TEXT REFERENCES delivery(id),
            relative_path TEXT NOT NULL CHECK (length(relative_path) BETWEEN 1 AND 512),
            device TEXT NOT NULL CHECK (length(device) BETWEEN 1 AND 20),
            inode TEXT NOT NULL CHECK (length(inode) BETWEEN 1 AND 20),
            byte_count INTEGER NOT NULL CHECK (byte_count BETWEEN 1 AND 2147483647),
            sha256 TEXT CHECK (sha256 IS NULL OR length(sha256) = 64),
            state TEXT NOT NULL CHECK (state IN ('reserved', 'attached', 'retired', 'deleted')),
            UNIQUE (delivery_id, relative_path),
            CHECK ((state = 'reserved' AND delivery_id IS NULL AND sha256 IS NULL)
                OR (state = 'attached' AND delivery_id IS NOT NULL AND sha256 IS NOT NULL)
                OR (state IN ('retired', 'deleted') AND (delivery_id IS NULL OR sha256 IS NOT NULL)))
        ) STRICT
        """,
        """
        CREATE TABLE recording_transfer (
            recording_id TEXT PRIMARY KEY NOT NULL REFERENCES recording_file(id) ON DELETE CASCADE,
            declaration BLOB NOT NULL CHECK (length(declaration) BETWEEN 1 AND 65536),
            declaration_sha256 TEXT NOT NULL CHECK (length(declaration_sha256) = 64),
            registration BLOB CHECK (registration IS NULL OR length(registration) BETWEEN 1 AND 4096),
            receipt BLOB CHECK (receipt IS NULL OR length(receipt) BETWEEN 1 AND 4096)
        ) STRICT
        """,
        """
        CREATE TABLE acquisition_query (
            id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
            local_id TEXT NOT NULL REFERENCES source_state(local_id),
            definition BLOB NOT NULL CHECK (length(definition) BETWEEN 1 AND 16384),
            checkpoint_revision TEXT NOT NULL CHECK (length(checkpoint_revision) = 36),
            cursor BLOB CHECK (cursor IS NULL OR length(cursor) BETWEEN 1 AND 65536),
            conversion_instant BLOB CHECK (conversion_instant IS NULL OR length(conversion_instant) BETWEEN 1 AND 128),
            last_served INTEGER NOT NULL DEFAULT 0 CHECK (last_served >= 0),
            query_exhausted INTEGER NOT NULL DEFAULT 0 CHECK (query_exhausted IN (0, 1))
        ) STRICT
        """,
        """
        CREATE TABLE healthkit_record_conversion (
            source_id TEXT NOT NULL REFERENCES source_state(source_id),
            record_id TEXT NOT NULL CHECK (length(record_id) = 36),
            configuration TEXT NOT NULL CHECK (length(configuration) = 64),
            recorded_at REAL NOT NULL CHECK (recorded_at BETWEEN 0 AND 253402300799),
            PRIMARY KEY (source_id, record_id, configuration)
        ) STRICT
        """,
        """
        CREATE TABLE deletion_detection (
            query_id TEXT NOT NULL REFERENCES acquisition_query(id),
            record_id TEXT NOT NULL CHECK (length(record_id) = 36),
            detected_at REAL NOT NULL CHECK (detected_at BETWEEN 0 AND 253402300799),
            PRIMARY KEY (query_id, record_id)
        ) STRICT
        """
    ]
}
