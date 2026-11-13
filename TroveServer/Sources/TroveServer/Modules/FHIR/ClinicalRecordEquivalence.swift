//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import TroveAPITypes


private struct ReferenceIndex: Decodable {
    struct Entry: Decodable {
        let fullUrl: String
        let resource: LiteralReferences
    }
    let entry: [Entry]
}


/// Reads strings and container structure only. Numeric tokens never enter a floating-point decoder.
private struct LiteralReferences: Decodable {
    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    let values: Set<String>

    init(from decoder: any Decoder) throws {
        var references: Set<String> = []
        if let object = try? decoder.container(keyedBy: Key.self) {
            for key in object.allKeys {
                if key.stringValue == "reference", let value = try? object.decode(String.self, forKey: key) {
                    references.insert(value)
                } else {
                    references.formUnion(try object.decode(Self.self, forKey: key).values)
                }
            }
        } else if var array = try? decoder.unkeyedContainer() {
            while !array.isAtEnd { references.formUnion(try array.decode(Self.self).values) }
        }
        values = references
    }
}


/// Compares validated record content without trusting its claimed keyed version or rounding number tokens.
enum ClinicalRecordEquivalence {
    static func accepts(_ bytes: Data, asRepresentationOf original: Data) throws -> Bool {
        let retained = try ExchangeRecord(validating: original)
        let incoming = try ExchangeRecord(validating: bytes)
        guard retained.kind == incoming.kind, retained.sourceRecord == incoming.sourceRecord,
              retained.version == incoming.version else {
            return false
        }
        // All reports of this source-record retraction have the same effect. Keep the
        // first Provenance and its recording time as the selected lifecycle evidence.
        if retained.kind == .retraction {
            return true
        }
        let oldEntries = try ExchangeRecordBytes(retained)
        let newEntries = try ExchangeRecordBytes(incoming)
        // Even optional snapshots cannot change their content under an existing entry key.
        for address in Set(oldEntries.entryFullURLs).intersection(newEntries.entryFullURLs) {
            guard oldEntries.entryBytes(for: address) == newEntries.entryBytes(for: address) else {
                return false
            }
        }
        let oldCore = try core(retained)
        let newCore = try core(incoming)
        guard oldCore == newCore else {
            return false
        }
        return oldCore.allSatisfy { oldEntries.entryBytes(for: $0) == newEntries.entryBytes(for: $0) }
    }

    /// Only a ResearchSubject and nodes reached solely from it may join outside this closure.
    /// Grove has already checked record membership and reference validity.
    private static func core(_ record: ExchangeRecord) throws -> Set<String> {
        let bundle = try JSONDecoder().decode(ReferenceIndex.self, from: record.json)
        let references = Dictionary(uniqueKeysWithValues: bundle.entry.map { ($0.fullUrl, $0.resource.values) })
        var pending = record.outputFullURLs + [record.version.fullURL]
        var reached: Set<String> = []
        while let address = pending.popLast() {
            guard reached.insert(address).inserted else { continue }
            pending.append(contentsOf: (references[address] ?? []).filter { references[$0] != nil })
        }
        return reached
    }
}
