//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import OpenAPIRuntime
import Testing
@testable import TroveCLI


private final class RecordingDirectory {
    let url: URL
    var output: URL { url.appendingPathComponent("recording.csv") }

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func entries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}


struct RecordingOutputTests {
    private func save(_ body: HTTPBody, in directory: RecordingDirectory, limit: Int64 = 1024) async throws {
        let output = try RecordingOutput(path: directory.output.path)
        try await output.save(body, maximumByteCount: limit)
    }

    private func streamed(_ chunks: [[UInt8]], failing: Bool = false, length: HTTPBody.Length = .unknown) -> HTTPBody {
        let stream = AsyncThrowingStream<ArraySlice<UInt8>, any Error> { continuation in
            for chunk in chunks {
                continuation.yield(chunk[...])
            }
            continuation.finish(throwing: failing ? CLIError.requestFailed : nil)
        }
        return HTTPBody(stream, length: length, iterationBehavior: .single)
    }

    @Test
    func preservesExactBytesAndOwnerOnlyPermissions() async throws {
        let directory = try RecordingDirectory()
        let bytes = Data("time,value\r\n1,12345678901234567890.123456789\r\n".utf8)
        try await save(HTTPBody(bytes), in: directory)
        #expect(try Data(contentsOf: directory.output) == bytes)
        #expect(try directory.entries() == ["recording.csv"])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.output.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test
    func refusesReuseWithoutModifyingPublishedOutput() async throws {
        let directory = try RecordingDirectory()
        let output = try RecordingOutput(path: directory.output.path)
        try await output.save(HTTPBody("first"), maximumByteCount: 1024)
        await #expect(throws: CLIError.recordingOutputFailed) {
            try await output.save(HTTPBody("second"), maximumByteCount: 1024)
        }
        #expect(try Data(contentsOf: directory.output) == Data("first".utf8))
    }

    @Test(arguments: [false, true])
    func refusesExistingFilesAndSymlinks(symlink: Bool) throws {
        let directory = try RecordingDirectory()
        if symlink {
            try FileManager.default.createSymbolicLink(at: directory.output, withDestinationURL: directory.url.appendingPathComponent("missing"))
        } else {
            try Data("existing".utf8).write(to: directory.output)
        }
        #expect(throws: CLIError.recordingOutputExists) {
            _ = try RecordingOutput(path: directory.output.path)
        }
        #expect(try directory.entries() == ["recording.csv"])
        if !symlink {
            #expect(try Data(contentsOf: directory.output) == Data("existing".utf8))
        }
    }

    @Test
    func preservesFileCreatedDuringTransfer() async throws {
        let directory = try RecordingDirectory()
        do {
            let output = try RecordingOutput(path: directory.output.path)
            try Data("winner".utf8).write(to: directory.output)
            await #expect(throws: CLIError.recordingOutputExists) {
                try await output.save(HTTPBody("download"), maximumByteCount: 1024)
            }
        }
        #expect(try Data(contentsOf: directory.output) == Data("winner".utf8))
        #expect(try directory.entries() == ["recording.csv"])
    }

    @Test(arguments: [HTTPBody.Length.known(8), .unknown])
    func rejectsOversizedBodiesAndRemovesStaging(length: HTTPBody.Length) async throws {
        let directory = try RecordingDirectory()
        await #expect(throws: CLIError.recordingTooLarge) {
            try await save(streamed([[1, 2, 3, 4], [5, 6, 7, 8]], length: length), in: directory, limit: 6)
        }
        #expect(try directory.entries().isEmpty)
    }

    @Test(arguments: [Int64(0), -1, Int64(Int32.max) + 1])
    func rejectsInvalidCapacity(limit: Int64) async throws {
        let directory = try RecordingDirectory()
        await #expect(throws: CLIError.recordingTooLarge) {
            try await save(HTTPBody("csv"), in: directory, limit: limit)
        }
        #expect(try directory.entries().isEmpty)
    }

    @Test
    func rejectsTruncationEmptyBodyAndFailedSource() async throws {
        let directory = try RecordingDirectory()
        for body in [streamed([[1, 2]], length: .known(4)), streamed([]), streamed([[1, 2]], failing: true)] {
            await #expect(throws: CLIError.requestFailed) {
                try await save(body, in: directory)
            }
            #expect(try directory.entries().isEmpty)
        }
    }

    @Test
    func cancellationRemovesPartialFile() async throws {
        let directory = try RecordingDirectory()
        let path = directory.output.path
        let task = Task {
            let output = try RecordingOutput(path: path)
            withUnsafeCurrentTask { $0?.cancel() }
            try await output.save(HTTPBody("csv"), maximumByteCount: 1024)
        }
        await #expect(throws: (any Error).self) {
            try await task.value
        }
        #expect(try directory.entries().isEmpty)
    }

    #if os(macOS)
    @Test
    func inheritedACLIsRejectedBeforeSensitiveWrites() throws {
        let directory = try RecordingDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.url.path)
        let change = Process()
        change.executableURL = URL(fileURLWithPath: "/bin/chmod")
        change.arguments = ["+a", "everyone allow read,search,file_inherit,directory_inherit", directory.url.path]
        try change.run()
        change.waitUntilExit()
        try #require(change.terminationStatus == 0)
        #expect(throws: CLIError.recordingOutputFailed) {
            _ = try RecordingOutput(path: directory.output.path)
        }
        #expect(try directory.entries().isEmpty)
    }
    #endif

    @Test
    func refusesUnavailableOutputDirectory() throws {
        let directory = try RecordingDirectory()
        #expect(throws: CLIError.recordingOutputFailed) {
            _ = try RecordingOutput(path: directory.output.appendingPathComponent("missing.csv").path)
        }
        #expect(try directory.entries().isEmpty)
    }
}
