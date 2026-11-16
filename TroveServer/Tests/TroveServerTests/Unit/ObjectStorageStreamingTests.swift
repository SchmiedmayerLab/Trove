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
@testable import TroveServer


struct ObjectStorageStreamingTests {
    @Test
    func oversizedDeclarationFailsWithoutReading() async throws {
        let source = ObjectStorageStreamSource(["abcdef"])
        #expect(throws: BoundedObjectStorageBody.StreamError.byteLimitExceeded) {
            try BoundedObjectStorageBody.wrap(source.body(length: .known(6)), maximumBytes: 5)
        }
        #expect(await source.reads == 0)
    }

    @Test(arguments: [HTTPBody.Length.unknown, .known(2)])
    func runningLimitRejectsExcessBeforeDeliveringIt(length: HTTPBody.Length) async throws {
        let source = ObjectStorageStreamSource(["ab", "cd", "ef", "unread"])
        let body = try BoundedObjectStorageBody.wrap(source.body(length: length), maximumBytes: 5)
        var iterator = body.makeAsyncIterator()
        #expect(await source.reads == 0)
        #expect(try await iterator.next() == ArraySlice("ab".utf8))
        #expect(await source.reads == 1)
        #expect(try await iterator.next() == ArraySlice("cd".utf8))
        await #expect(throws: BoundedObjectStorageBody.StreamError.byteLimitExceeded) { try await iterator.next() }
        #expect(try await iterator.next() == nil)
        #expect(await source.reads == 3)
    }

    @Test
    func exactLimitEmptyChunksAndUpstreamFailureArePreserved() async throws {
        let source = ObjectStorageStreamSource(["", "ab", "", "cd", ""])
        let body = try BoundedObjectStorageBody.wrap(source.body(), maximumBytes: 4)
        #expect(try await Data(collecting: body, upTo: 4) == Data("abcd".utf8))
        let failure = ObjectStorageStreamSource(["ab", "cd"], failureAt: 1)
        let failed = try BoundedObjectStorageBody.wrap(failure.body(), maximumBytes: 4)
        await #expect(throws: ObjectStorageStreamSource.Failure.interrupted) { try await Data(collecting: failed, upTo: 4) }
        #expect(await failure.reads == 2)
    }

    @Test(arguments: [0, 1])
    func cancellationAtAChunkOrEOFIsNotSuccessfulCompletion(index: Int) async throws {
        let source = ObjectStorageStreamSource(["ab"], cancellationAt: index)
        let task = Task {
            let body = try BoundedObjectStorageBody.wrap(source.body(), maximumBytes: 2)
            return try await Data(collecting: body, upTo: 2)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await source.reads == index + 1)
    }

    @Test
    func integrityVerificationChecksExactSizeAndDigest() async throws {
        let provider = InMemoryObjectStorageProvider()
        let storage = ObjectStorageService(provider: provider)
        let bytes = Data("abcdef".utf8)
        let source = ObjectStorageStreamSource(["ab", "", "c", "def"])
        try await storage.upload(body: source.body(length: .known(6)), key: "synthetic", contentType: "application/octet-stream")
        try await storage.verify(key: "synthetic", byteCount: bytes.count, digest: ArtifactStore.digest(bytes))
        for count in [5, 6, 7] {
            await #expect {
                try await storage.verify(key: "synthetic", byteCount: count, digest: ArtifactStore.digest(Data("wrong".utf8)))
            } throws: { ($0 as? TroveServer.ServerError)?.status.code == 409 }
        }
    }
}
