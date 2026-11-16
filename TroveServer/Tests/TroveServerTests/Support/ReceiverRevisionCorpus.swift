//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPITypes
@testable import TroveServer


/// Uses the pinned IG's declarative states, with its identifier tie-break rebound to the test deployment.
struct ReceiverRevisionCorpus: Decodable, Sendable {
    struct State: Decodable, Sendable {
        let history: [String]
        let versions: [String]
        let current: [String]
        let visible: [String]
        let newlyVisible: [String]
    }

    struct Step: Decodable, Sendable {
        let bundle: String
        let expect: State
    }

    struct Sequence: Decodable, Sendable {
        let id: String
        let steps: [Step]
    }

    struct PreparedEvent: Decodable, Sendable {
        let bytesBase64: String
        let addresses: [String: String]
        let selected: [String]

        var bytes: Data {
            get throws { try #require(Data(base64Encoded: bytesBase64)) }
        }
    }

    struct Prepared: Decodable, Sendable {
        let corpus: ReceiverRevisionCorpus
        let events: [String: PreparedEvent]
    }

    let schemaVersion: Int
    let bundles: String
    let sequences: [Sequence]

    static func prepare(source: SourceBinding) throws -> Prepared {
        let corpus = try #require(ProcessInfo.processInfo.environment["TROVE_TEST_LIFECYCLE_CORPUS"])
        let assets = try #require(ProcessInfo.processInfo.environment["TROVE_TEST_VALIDATOR_ASSETS"])
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", root.appendingPathComponent("TroveInfrastructure/validator/prepare_revision_corpus.py").path,
            "--assets", assets, "--corpus", corpus,
            "--identifier-root", source.identifierRoot, "--registration-id", source.registrationID.uuidString.lowercased(),
            "--participant-system", source.participantIdentifierSystem, "--participant-value", source.participantIdentifierValue,
            "--effective-at", try TroveDateTranscoder().encode(Date())
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let bytes = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "Pinned corpus checksums, ordering evidence and declarative expectations must agree")
        let prepared = try JSONDecoder().decode(Prepared.self, from: bytes)
        try #require(prepared.corpus.schemaVersion == 0 && prepared.corpus.bundles == "bundles.json")
        try #require(prepared.corpus.sequences.count == 43 && Set(prepared.corpus.sequences.map(\.id)).count == 43)
        try #require(prepared.events.count == 8)
        for event in prepared.events.values {
            try #require(!event.bytes.isEmpty && event.bytes.count <= FHIRValidationClient.maximumBytes && !event.selected.isEmpty)
        }
        return prepared
    }
}
