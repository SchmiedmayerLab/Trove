//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import CTroveDeliverySQLite
import Foundation


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

    static func configure(_ database: DeliverySQLite, scope: DeliveryScope, contract: String, create: Bool, maximumBytes: Int) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let scopeBytes = try encoder.encode(Identity(scope: scope, contract: contract))
        if !create {
            let version = try database.query("PRAGMA user_version") { sqlite3_column_int64($0, 0) }
            guard version == [5] else { throw DeliveryJournalError.unsupportedFormat }
            let stored = try database.query("SELECT scope FROM journal_identity WHERE id = 1") { try DeliverySQLite.blob($0, 0) }
            guard stored == [scopeBytes] else { throw DeliveryJournalError.wrongScope }
        }
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
        let maximumPages = Int64(maximumBytes) / pageSize
        // Only a checked integer derived from configuration is interpolated into this pragma.
        let acceptedPages = try database.query("PRAGMA max_page_count = \(maximumPages)") { sqlite3_column_int64($0, 0) }
        guard acceptedPages == [maximumPages] else { throw DeliveryJournalError.capacityExceeded }
        if create {
            try database.transaction {
                for statement in statements { try database.execute(statement) }
                try database.execute("INSERT INTO journal_identity(id, scope) VALUES (1, ?)", [.blob(scopeBytes)])
                try database.execute("PRAGMA user_version = 5")
            }
        }
    }
}


extension DeliveryJournalSchema {
    private static let statements = [
        "CREATE TABLE journal_identity (id INTEGER PRIMARY KEY CHECK (id = 1), scope BLOB NOT NULL) STRICT",
        """
        CREATE TABLE source_state (
            local_id TEXT PRIMARY KEY NOT NULL CHECK (length(local_id) = 36),
            source_id TEXT UNIQUE,
            producer_system TEXT,
            privacy_key BLOB NOT NULL CHECK (length(privacy_key) = 32),
            binding BLOB CHECK (binding IS NULL OR length(binding) BETWEEN 1 AND 16384),
            next_sequence INTEGER NOT NULL CHECK (next_sequence > 0),
            query_definition BLOB NOT NULL CHECK (length(query_definition) BETWEEN 1 AND 16384),
            checkpoint_revision TEXT NOT NULL CHECK (length(checkpoint_revision) = 36),
            cursor BLOB CHECK (cursor IS NULL OR length(cursor) BETWEEN 1 AND 65536),
            CHECK ((source_id IS NULL AND producer_system IS NULL AND binding IS NULL AND next_sequence = 1 AND cursor IS NULL)
                OR (source_id IS NOT NULL AND length(source_id) = 36 AND producer_system IS NOT NULL
                    AND length(producer_system) BETWEEN 1 AND 512 AND binding IS NOT NULL))
        ) STRICT
        """,
        """
        CREATE TABLE delivery (
            id TEXT PRIMARY KEY NOT NULL,
            source_id TEXT NOT NULL REFERENCES source_state(source_id),
            sequence INTEGER NOT NULL CHECK (sequence > 0),
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
            CHECK ((payload IS NOT NULL AND length(payload) BETWEEN 1 AND 4194304 AND receipt IS NULL)
                OR (payload IS NULL AND receipt IS NOT NULL AND blocked IS NULL AND retry_after = 0))
        ) STRICT
        """
    ]
}
