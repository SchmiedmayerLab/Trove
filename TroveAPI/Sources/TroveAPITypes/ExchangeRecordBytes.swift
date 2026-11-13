//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract


/// Retains entry tokens while restoring a staged record's entry order after Bundle packing.
/// Grove owns JSON and graph validation; this adapter only slices its canonical one-record bytes.
public struct ExchangeRecordBytes: Sendable {
    public enum Failure: Error, Equatable {
        case invalidEntries
    }

    private struct Entry: Decodable {
        let fullUrl: String
    }

    public let entryFullURLs: [String]
    private let entries: [String: Data]
    private let suffix: Data
    private let version: RecordVersion

    public init(_ record: ExchangeRecord) throws {
        let bytes = Array(record.json)
        let prefix = Array("{\"entry\":[".utf8)
        guard bytes.starts(with: prefix) else { throw Failure.invalidEntries }
        var offset = prefix.count
        var entries: [String: Data] = [:]
        var ordered: [String] = []
        while offset < bytes.count, bytes[offset] != UInt8(ascii: "]") {
            let start = offset
            offset = try Self.endOfEntry(in: bytes, from: start)
            let entryBytes = Data(bytes[start..<offset])
            let entry = try JSONDecoder().decode(Entry.self, from: entryBytes)
            guard entries.updateValue(entryBytes, forKey: entry.fullUrl) == nil else { throw Failure.invalidEntries }
            ordered.append(entry.fullUrl)
            if offset < bytes.count, bytes[offset] == UInt8(ascii: ",") { offset += 1 }
        }
        guard !ordered.isEmpty, offset < bytes.count, bytes[offset] == UInt8(ascii: "]") else { throw Failure.invalidEntries }
        self.entryFullURLs = ordered
        self.entries = entries
        self.suffix = Data(bytes[offset...])
        self.version = record.version
    }

    /// The sender names the original ordered entries; these names confer no collection or study authority.
    /// Revalidation requires a complete record closure and rejects unrelated or missing required nodes.
    public func restoring(entryFullURLs: [String]) throws -> ExchangeRecord {
        guard !entryFullURLs.isEmpty, entryFullURLs.count <= entries.count,
              Set(entryFullURLs).count == entryFullURLs.count else { throw Failure.invalidEntries }
        var bytes = Data("{\"entry\":[".utf8)
        for (index, fullURL) in entryFullURLs.enumerated() {
            guard let entry = entries[fullURL] else { throw Failure.invalidEntries }
            if index > 0 { bytes.append(UInt8(ascii: ",")) }
            bytes.append(entry)
        }
        bytes.append(suffix)
        let record = try ExchangeRecord(validating: bytes)
        guard record.version == version, record.json == bytes else { throw Failure.invalidEntries }
        return record
    }
}


extension ExchangeRecordBytes {
    /// Input is already Grove's validated canonical JSON. Braces inside strings are not delimiters.
    private static func endOfEntry(in bytes: [UInt8], from start: Int) throws -> Int {
        guard bytes[start] == UInt8(ascii: "{") else { throw Failure.invalidEntries }
        var depth = 0
        var quoted = false
        var escaped = false
        for offset in start..<bytes.count {
            let byte = bytes[offset]
            switch (quoted, escaped, byte) {
            case (true, true, _): escaped = false
            case (true, false, UInt8(ascii: "\\")): escaped = true
            case (_, _, UInt8(ascii: "\"")): quoted.toggle()
            case (false, _, UInt8(ascii: "{")): depth += 1
            case (false, _, UInt8(ascii: "}")):
                depth -= 1
                if depth == 0 {
                    return offset + 1
                }
            default: break
            }
        }
        throw Failure.invalidEntries
    }
}
