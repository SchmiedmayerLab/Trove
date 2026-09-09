//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import Testing
@testable import TroveServer


/// Consumes the IG's declared outcomes, not another implementation of revision selection.
struct ReceiverRevisionCorpus: Decodable, Sendable {
    struct Output: Decodable, Sendable {
        let event: String
        let fullUrl: String
    }

    struct State: Decodable, Sendable {
        let history: [String]
        let versions: [String]
        let current: [String]
        let conflicts: [String]
        let visible: [String]
        let newlyVisible: [String]
    }

    struct Step: Decodable, Sendable {
        let event: String
        let expect: State
    }

    struct Sequence: Decodable, Sendable {
        let id: String
        let steps: [Step]
    }

    struct EventIndex: Decodable {
        struct Event: Decodable {
            let path: String
            let sha256: String
            let eventIdentity: Identity
        }

        struct Identity: Decodable {
            let value: String
        }

        let events: [String: Event]
    }

    struct PreparedEvent: Sendable {
        let bytes: Data
        let addresses: [String: String]
        let selected: [String]
    }

    struct Envelope: Decodable {
        struct Entry: Decodable { let fullUrl: String }
        let entry: [Entry]
    }

    let schemaVersion: Int
    let events: String
    let outputs: [String: Output]
    let authorizedOutputs: [String: [String]]
    let sequences: [Sequence]

    static func load() throws -> (Self, URL) {
        let path = try #require(ProcessInfo.processInfo.environment["TROVE_TEST_LIFECYCLE_CORPUS"])
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let corpus = try JSONDecoder().decode(Self.self, from: Data(contentsOf: root.appendingPathComponent("revision-sequences.json")))
        try #require(corpus.schemaVersion == 0 && corpus.sequences.count == 35, "Update the explicit acceptance matrix when the IG corpus changes")
        try #require(Set(corpus.sequences.map(\.id)).count == corpus.sequences.count)
        try #require(corpus.events == "events.json" && corpus.authorizedOutputs["purpose-b"]?.isEmpty == true)
        return (corpus, root)
    }

    func prepare(sequence: Sequence, source: SourceBinding, root: URL) throws -> [String: PreparedEvent] {
        let index = try JSONDecoder().decode(EventIndex.self, from: Data(contentsOf: root.appendingPathComponent(events)))
        let selected = Set(try #require(authorizedOutputs["purpose-a"]))
        let collectedAt = Date()
        var prepared: [String: PreparedEvent] = [:]
        for name in Set(sequence.steps.map(\.event)).sorted() {
            let event = try #require(index.events[name])
            try #require(event.path == "resources/\(name).json", "Fixture path must remain inside the selected corpus")
            let url = root.appendingPathComponent(event.path)
            let original = try Data(contentsOf: url)
            try #require(SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined() == event.sha256)
            let number = try #require(event.eventIdentity.value.split(separator: ":").last.flatMap { UInt64($0) })
            let bytes = try ImmutablePointEventFixture.bytes(source: source, effectiveAt: collectedAt, fixtureURL: url, sequence: number)
            let before = try JSONDecoder().decode(Envelope.self, from: original)
            let after = try JSONDecoder().decode(Envelope.self, from: bytes)
            try #require(before.entry.count == after.entry.count)
            var addresses: [String: String] = [:]
            for (alias, output) in outputs where output.event == name {
                let ordinal = try #require(before.entry.firstIndex { $0.fullUrl == output.fullUrl })
                addresses[alias] = after.entry[ordinal].fullUrl
            }
            let targets = addresses.filter { selected.contains($0.key) }.map(\.value).sorted()
            try #require(!targets.isEmpty)
            prepared[name] = .init(bytes: bytes, addresses: addresses, selected: targets)
        }
        return prepared
    }
}
