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
@testable import TroveAPIClient


struct RecordingUploadBodyTests {
    @Test
    func largeSnapshotIsReplayableInBoundedChunksAndUnaffectedBySourceMutation() async throws {
        try await DeliveryFixture.withJournal { _, databaseURL in
            let url = databaseURL.deletingLastPathComponent().appendingPathComponent("large-recording.csv")
            try #require(FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]))
            let writer = try FileHandle(forWritingTo: url)
            let chunk = Data(repeating: 0x41, count: 64 * 1024)
            var original = SHA256()
            for _ in 0..<1536 {
                try writer.write(contentsOf: chunk)
                original.update(data: chunk)
            }
            try writer.write(contentsOf: Data([42]))
            original.update(data: Data([42]))
            try writer.close()
            let digest = original.finalize().map { String(format: "%02x", $0) }.joined()
            let count = Int64(96 * 1024 * 1024 + 1)
            let upload = try RecordingUploadBody(url: url, byteCount: count, sha256: digest)
            let replacement = try FileHandle(forWritingTo: url)
            try replacement.truncate(atOffset: 1)
            try replacement.close()
            for _ in 0..<2 {
                var received = 0, hash = SHA256(), chunks = 0
                for try await bytes in upload.body {
                    #expect(bytes.count <= 64 * 1024)
                    received += bytes.count
                    hash.update(data: bytes)
                    chunks += 1
                }
                #expect(Int64(received) == count && chunks == 1537)
                #expect(hash.finalize().map { String(format: "%02x", $0) }.joined() == digest)
            }
        }
    }
}
