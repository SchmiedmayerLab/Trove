//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

#if os(Linux)
import Foundation
import Glibc
import Testing
@testable import TroveAPIClient


/// Exercises SQLite recovery after process termination without actor or file-descriptor cleanup.
struct DeliveryRecordingCrashTests {
    @Test
    func processTerminationPreservesOnlyCommittedCheckpoints() async throws {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["TROVE_TEST_RECORDING_CRASH_PATH"] {
            try await Self.terminateWriter(url: URL(fileURLWithPath: path), environment: environment)
            return
        }
        for committed in [false, true] {
            try await DeliveryFixture.withJournal { journal, url in
                let initial = try await journal.checkpoint(for: DeliveryFixture.sourceID)
                await journal.close()
                let process = Process()
                process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                process.arguments = ["--testing-library", "swift-testing", "--filter", "DeliveryRecordingCrashTests"]
                var childEnvironment = environment
                childEnvironment["TROVE_TEST_RECORDING_CRASH_PATH"] = url.path
                childEnvironment["TROVE_TEST_RECORDING_CRASH_COMMITTED"] = committed ? "1" : "0"
                process.environment = childEnvironment
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                try #require(process.terminationReason == .exit && process.terminationStatus == 73)
                let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
                let pending = try await reopened.pendingDeliveryIDs()
                let files = try FileManager.default.contentsOfDirectory(at: url.appendingPathExtension("recordings"), includingPropertiesForKeys: nil)
                let file = try #require(files.first)
                #expect(files.count == 1)
                #expect(try Data(contentsOf: file) == (committed ? Data([1, 2, 3]) : Data([1])))
                if committed {
                    let id = try #require(pending.first)
                    #expect(pending.count == 1)
                    #expect(try await reopened.recordingReferences(for: id).count == 1)
                    #expect(try await reopened.checkpoint(for: DeliveryFixture.sourceID).cursor == Data([7]))
                    #expect(try await reopened.reclaimRecordingFiles() == 0)
                } else {
                    #expect(pending.isEmpty)
                    #expect(try await reopened.checkpoint(for: DeliveryFixture.sourceID) == initial)
                    #expect(try await reopened.reclaimRecordingFiles() == 1)
                    #expect(!FileManager.default.fileExists(atPath: file.path))
                }
                await reopened.close()
            }
        }
    }
}


extension DeliveryRecordingCrashTests {
    private static func terminateWriter(url: URL, environment: [String: String]) async throws {
        let committed = environment["TROVE_TEST_RECORDING_CRASH_COMMITTED"] == "1"
        let journal = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
        let setup = try #require(await journal.sourceSetups().first)
        let binding = try #require(setup.binding)
        let sourceID = try #require(UUID(uuidString: binding.source.id))
        let checkpoint = try await journal.checkpoint(for: sourceID)
        let base = try DeliveryFixture.payload(sequence: 1, changes: ["recording"], sourceID: sourceID, registrationID: setup.localID)
        let recording = DeliveryRecording(relativePath: "recordings/route.csv", byteCount: 3) { consume in
            try consume(Data([1]))
            if !committed { _exit(73) }
            try consume(Data([2, 3]))
        }
        _ = try await journal.stage(from: checkpoint, nextCursor: Data([7]), payloads: [
            .init(bytes: base.bytes, targets: base.targets, recordings: [recording])
        ])
        _exit(73)
    }
}
#endif
