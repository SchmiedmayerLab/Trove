//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// An immutable start-date predicate. Historical ranges are half-open; live queries have no upper bound.
public struct HeartRateQueryDefinition: Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case live, historical }
    public enum DefinitionError: Error { case invalidDefinition }

    private struct Storage: Codable {
        let adapter: String
        let version: Int
        let kind: Kind
        let start: Date
        let end: Date?
    }

    public let kind: Kind
    public let start: Date
    public let end: Date?

    public init(kind: Kind, start: Date, end: Date? = nil) throws {
        guard Self.validDate(start), end.map(Self.validDate) ?? true,
              kind == .live ? end == nil : end.map({ $0 > start }) == true else { throw DefinitionError.invalidDefinition }
        self.kind = kind
        self.start = start
        self.end = end
    }

    /// Reject unknown versions, extra fields and noncanonical definitions rather than silently resetting their anchors.
    public init(bytes: Data) throws {
        guard (1...16_384).contains(bytes.count) else { throw DefinitionError.invalidDefinition }
        let stored = try JSONDecoder().decode(Storage.self, from: bytes)
        guard stored.adapter == "healthkit-heart-rate", stored.version == 4 else { throw DefinitionError.invalidDefinition }
        try self.init(kind: stored.kind, start: stored.start, end: stored.end)
        guard try encoded() == bytes else { throw DefinitionError.invalidDefinition }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Storage(adapter: "healthkit-heart-rate", version: 4, kind: kind, start: start, end: end))
    }

    public func contains(_ sampleStart: Date) -> Bool {
        sampleStart >= start && (end.map { sampleStart < $0 } ?? true)
    }
}


extension HeartRateQueryDefinition {
    static func validDate(_ date: Date) -> Bool {
        (-62_135_596_800...253_402_300_799).contains(date.timeIntervalSince1970)
    }
}
