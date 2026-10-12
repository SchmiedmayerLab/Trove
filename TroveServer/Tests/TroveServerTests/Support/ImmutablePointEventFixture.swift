//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import TroveServer


enum ImmutablePointEventFixture {
    /// Synthetic immutable Mobile point output derived from a questionnaire response.
    /// Binding and consent are established by the real server services before rekeying this event.
    static func bytes(
        source: SourceBinding, effectiveAt: Date = Date(), fixtureURL: URL? = nil, sequence: UInt64 = 50
    ) throws -> Data {
        let url = try #require(fixtureURL ?? Bundle.module.url(forResource: "ImmutablePointEvent", withExtension: "json"))
        let assets = try #require(ProcessInfo.processInfo.environment["TROVE_TEST_VALIDATOR_ASSETS"])
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let timestamp = effectiveAt.formatted(.iso8601
            .year()
            .month()
            .day()
            .dateSeparator(.dash)
            .time(includingFractionalSeconds: true)
            .timeZone(separator: .colon))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", root.appendingPathComponent("TroveInfrastructure/validator/rekey_fixture.py").path,
            "--assets", assets, "--fixture", url.path,
            "--event-system", source.eventIdentifierSystem, "--producer-instance", source.id.uuidString.lowercased(),
            "--participant-system", source.participantIdentifierSystem, "--participant-value", source.participantIdentifierValue,
            "--effective-at", timestamp, "--sequence", String(sequence)
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let bytes = try #require(try output.fileHandleForReading.readToEnd())
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "Pinned test fixture identity generation must succeed")
        try #require(!bytes.isEmpty && bytes.count <= FHIRValidationClient.maximumBytes)
        return bytes
    }
}
