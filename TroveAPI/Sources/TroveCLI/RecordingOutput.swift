//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import OpenAPIRuntime


#if canImport(Darwin)
import Darwin


#else
import Glibc


#endif


/// Owns private staging storage on the destination filesystem, then publishes without replacing any path.
final class RecordingOutput {
    private let destination: URL
    private let directory: URL
    private let staging: URL
    private let handle: FileHandle
    private var started = false

    init(path: String) throws {
        let destination = URL(fileURLWithPath: path)
        var info = stat()
        guard lstat(destination.path, &info) != 0 else {
            throw CLIError.recordingOutputExists
        }
        guard errno == ENOENT, !destination.lastPathComponent.isEmpty else {
            throw CLIError.recordingOutputFailed
        }
        let template = destination.deletingLastPathComponent().appendingPathComponent(".trove-recording-XXXXXX").path
        var name = Array(template.utf8CString)
        guard mkdtemp(&name) != nil else {
            throw CLIError.recordingOutputFailed
        }
        let directory = URL(fileURLWithPath: String(decoding: name.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self))
        let staging = directory.appendingPathComponent("content")
        let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            _ = rmdir(directory.path)
            throw CLIError.recordingOutputFailed
        }
        do {
            try Self.checkACL(of: directory.path)
            try Self.checkACL(of: staging.path)
        } catch {
            close(descriptor)
            _ = unlink(staging.path)
            _ = rmdir(directory.path)
            throw error
        }
        self.destination = destination
        self.directory = directory
        self.staging = staging
        self.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func checkACL(of path: String) throws {
        #if canImport(Darwin)
        // Darwin ACL entries can grant access beyond the owner-only mode bits.
        guard let security = filesec_init() else { throw CLIError.recordingOutputFailed }
        defer { filesec_free(security) }
        var metadata = stat()
        var present: Int32 = 1
        guard path.withCString({ lstatx_np($0, &metadata, security) }) == 0,
              filesec_query_property(security, FILESEC_ACL, &present) == 0, present == 0 else {
            throw CLIError.recordingOutputFailed
        }
        #endif
    }

    func save(_ body: HTTPBody, maximumByteCount: Int64) async throws {
        guard !started else {
            throw CLIError.recordingOutputFailed
        }
        started = true
        guard (1...Int64(Int32.max)).contains(maximumByteCount) else {
            throw CLIError.recordingTooLarge
        }
        if case let .known(length) = body.length, length > maximumByteCount {
            throw CLIError.recordingTooLarge
        }
        var count: Int64 = 0
        do {
            for try await chunk in body {
                try Task.checkCancellation()
                guard Int64(chunk.count) <= maximumByteCount - count else {
                    throw CLIError.recordingTooLarge
                }
                try append(chunk)
                count += Int64(chunk.count)
            }
        } catch {
            throw CLIError.sanitized(error)
        }
        guard count > 0 else {
            throw CLIError.requestFailed
        }
        if case let .known(length) = body.length, length != count {
            throw CLIError.requestFailed
        }
        try Task.checkCancellation()
        guard fsync(handle.fileDescriptor) == 0 else {
            throw CLIError.recordingOutputFailed
        }
        try Task.checkCancellation()
        // link() is exclusive even if another process creates the destination during transfer.
        guard link(staging.path, destination.path) == 0 else {
            throw errno == EEXIST ? CLIError.recordingOutputExists : CLIError.recordingOutputFailed
        }
    }

    private func append(_ chunk: ArraySlice<UInt8>) throws {
        var offset = chunk.startIndex
        while offset < chunk.endIndex {
            try Task.checkCancellation()
            let end = min(offset + 64 * 1024, chunk.endIndex)
            do {
                try handle.write(contentsOf: Data(chunk[offset..<end]))
            } catch {
                throw CLIError.recordingOutputFailed
            }
            offset = end
        }
    }

    deinit {
        try? handle.close()
        _ = unlink(staging.path)
        _ = rmdir(directory.path)
    }
}
