//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

// The CLI loopback server uses desktop subprocess APIs.
#if os(macOS) || os(Linux)

import Foundation
import Testing
@testable import TroveCLI


private final class RecordingServer {
    let directory: URL
    let port: String
    private let process: Process

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", "-u", try #require(Bundle.module.url(forResource: "recording-server", withExtension: "py")).path,
            directory.appendingPathComponent("requests.jsonl").path
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            var line = Data()
            while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) {
                line.append(byte)
            }
            let port = try #require(String(data: line, encoding: .utf8))
            #expect(Int(port) != nil)
            self.directory = directory
            self.port = port
            self.process = process
        } catch {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func options(mode: String) throws -> ConnectionOptions {
        let token = directory.appendingPathComponent("token")
        try Data("synthetic-test-credential".utf8).write(to: token)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
        return try ConnectionOptions.parse([
            "--server", "http://127.0.0.1:\(port)/\(mode)", "--allow-insecure-loopback", "--token-file", token.path
        ])
    }

    func entries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    func log() throws -> String {
        try String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
    }

    deinit {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
    }
}


struct RecordingDownloadIntegrationTests {
    @Test
    func streamsAuthorizedCSVWithoutFollowingRedirects() async throws {
        let server = try RecordingServer()
        let options = try server.options(mode: "small")
        let destination = server.directory.appendingPathComponent("recording.csv")
        try await options.withRecordingClient { client in
            let output = try RecordingOutput(path: destination.path)
            let body = try await client.getStudyRecording(UUID(), grant: UUID(), versions: .current)
            try await output.save(body, maximumByteCount: 1024)
        }
        #expect(try Data(contentsOf: destination) == Data(String(repeating: "1,2\n", count: 256).utf8))
        #expect(try server.log().contains("\"authorized\": true"))
        #expect(try server.log().contains("\"identity_encoding\": true"))
        let redirect = try server.options(mode: "redirect")
        await #expect(throws: CLIError.httpStatus(302)) {
            try await redirect.withRecordingClient { client in
                _ = try await client.getStudyRecording(UUID(), grant: UUID(), versions: .current)
            }
        }
        #expect(try !server.log().contains("/forbidden"))
    }

    @Test
    func pausedConsumerDoesNotBufferCompleteNetworkResponse() async throws {
        let server = try RecordingServer()
        let options = try server.options(mode: "large")
        try await options.withRecordingClient { client in
            let body = try await client.getStudyRecording(UUID(), grant: UUID(), versions: .current)
            var iterator = body.makeAsyncIterator()
            #expect(try await iterator.next() != nil)
            try await Task.sleep(for: .milliseconds(150))
            // The loopback producer must still be blocked well before completing 128 MiB.
            #expect(try !server.log().contains("\"total\": 134217728"))
        }
    }

    @Test(arguments: ["large", "unknown"])
    func stopsOversizedNetworkResponsesAndCleansStaging(mode: String) async throws {
        let server = try RecordingServer()
        let options = try server.options(mode: mode)
        await #expect(throws: CLIError.recordingTooLarge) {
            try await options.withRecordingClient { client in
                let output = try RecordingOutput(path: server.directory.appendingPathComponent("output.csv").path)
                let body = try await client.getStudyRecording(UUID(), grant: UUID(), versions: .current)
                try await output.save(body, maximumByteCount: 64 * 1024)
            }
        }
        #expect(try !server.entries().contains("output.csv"))
        #expect(try !server.entries().contains(where: { $0.hasPrefix(".trove-recording-") }))
    }

    @Test
    func cancelsActiveNetworkDownloadAndCleansStaging() async throws {
        let server = try RecordingServer()
        let options = try server.options(mode: "slow")
        let destination = server.directory.appendingPathComponent("output.csv")
        let task = Task {
            try await options.withRecordingClient { client in
                let output = try RecordingOutput(path: destination.path)
                let body = try await client.getStudyRecording(UUID(), grant: UUID(), versions: .current)
                try await output.save(body, maximumByteCount: 16 * 1024 * 1024)
            }
        }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        await #expect(throws: (any Error).self) {
            try await task.value
        }
        #expect(try !server.entries().contains("output.csv"))
        #expect(try !server.entries().contains(where: { $0.hasPrefix(".trove-recording-") }))
    }
}

#endif
