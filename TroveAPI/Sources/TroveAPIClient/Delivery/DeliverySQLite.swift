//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import CTroveDeliverySQLite
import Foundation


/// Private connection owned exclusively by DeliveryJournal; never crosses actor isolation.
final class DeliverySQLite {
    enum Value {
        case text(String)
        case blob(Data)
        case integer(Int64)
        case real(Double)
    }

    struct Failure: Error {
        // Deliberately excludes SQL, paths and database values from diagnostics.
        let code: Int32
    }

    private var handle: OpaquePointer?

    init(url: URL) throws {
        let url = try Self.databaseURL(url)
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard result == SQLITE_OK else {
            sqlite3_close(handle)
            handle = nil
            throw Failure(code: result)
        }
        guard sqlite3_db_readonly(handle, "main") == 0 else {
            close()
            throw Failure(code: SQLITE_READONLY)
        }
        // Contention is retriable; do not block a cooperative executor waiting for another writer.
        sqlite3_busy_timeout(handle, 0)
    }

    func close() {
        sqlite3_close(handle)
        handle = nil
    }

    func execute(_ sql: String, _ values: [Value] = []) throws {
        _ = try query(sql, values) { _ in () }
    }

    func query<Result>(_ sql: String, _ values: [Value] = [], read: (OpaquePointer) throws -> Result) throws -> [Result] {
        guard let handle else { throw Failure(code: SQLITE_MISUSE) }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw Failure(code: prepared) }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        var rows: [Result] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(try read(statement))
            case SQLITE_DONE: return rows
            default: throw Failure(code: sqlite3_errcode(handle))
            }
        }
    }

    private func bind(_ values: [Value], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text):
                result = text.withCString { trove_delivery_bind_text(statement, index, $0, Int32(text.utf8.count)) }
            case .blob(let bytes):
                result = bytes.withUnsafeBytes { trove_delivery_bind_blob(statement, index, $0.baseAddress, Int32($0.count)) }
            case .integer(let integer):
                result = sqlite3_bind_int64(statement, index, integer)
            case .real(let number):
                result = sqlite3_bind_double(statement, index, number)
            }
            guard result == SQLITE_OK else { throw Failure(code: result) }
        }
    }

    func transaction<Result>(_ operation: () throws -> Result) throws -> Result {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try operation()
            try execute("COMMIT")
            return value
        } catch {
            // SQLITE_FULL may already have rolled back the complete transaction.
            if let handle, sqlite3_get_autocommit(handle) == 0 {
                do {
                    try execute("ROLLBACK")
                } catch {
                    // An indeterminate connection must never be reused to acknowledge work.
                    close()
                }
            }
            throw error
        }
    }

    deinit {
        sqlite3_close(handle)
    }
}


extension DeliverySQLite {
    static func databaseURL(_ url: URL) throws -> URL {
        // Foundation may intentionally retain /var on Darwin. Resolve only the parent;
        // resolving the database itself would bypass SQLite's final-component NOFOLLOW check.
        guard let parent = realpath(url.deletingLastPathComponent().path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: trove_delivery_current_errno()) ?? .EINVAL)
        }
        defer { free(parent) }
        return URL(fileURLWithPath: String(cString: parent), isDirectory: true).appendingPathComponent(url.lastPathComponent)
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let pointer = sqlite3_column_text(statement, column),
              let value = String(
                  bytes: UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8
              ) else {
            throw DeliveryJournalError.corruptJournal
        }
        return value
    }

    static func blob(_ statement: OpaquePointer, _ column: Int32) throws -> Data {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB, let pointer = sqlite3_column_blob(statement, column) else {
            throw DeliveryJournalError.corruptJournal
        }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
    }
}
