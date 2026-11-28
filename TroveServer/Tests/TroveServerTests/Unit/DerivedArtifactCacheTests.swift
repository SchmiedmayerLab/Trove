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


struct DerivedArtifactCacheTests {
    private let source = String(repeating: "a", count: 64)
    private let bytes = Data("derived".utf8)

    private func cache() -> (DerivedArtifactCache, InMemoryObjectStorageProvider) {
        let provider = InMemoryObjectStorageProvider()
        return (DerivedArtifactCache(storage: ObjectStorageService(provider: provider)), provider)
    }

    @Test
    func missDerivesOnceAndHitReadsTheEntry() async throws {
        let (cache, provider) = cache()
        let content = ArtifactStore.digest(bytes)
        var derivations = 0
        for _ in 0..<2 {
            let read = try await cache.entry(source: source, kind: .questionnaire, content: content, maximumBytes: 1024) {
                derivations += 1
                return bytes
            }
            #expect(read == bytes)
        }
        #expect(derivations == 1)
        #expect(try await provider.keys(prefix: "derived/") == [DerivedArtifactCache.key(source: source, kind: .questionnaire, content: content)])
    }

    @Test
    func corruptEntryIsDerivedAgainAndOtherDerivedBytesAreRefused() async throws {
        let (cache, provider) = cache()
        let content = ArtifactStore.digest(bytes)
        let key = DerivedArtifactCache.key(source: source, kind: .questionnaire, content: content)
        try await provider.upload(data: Data("corrupt".utf8), key: key, contentType: "application/octet-stream")
        #expect(try await cache.entry(source: source, kind: .questionnaire, content: content, maximumBytes: 1024) { bytes } == bytes)
        #expect(try await provider.download(key: key) == bytes)
        await #expect(throws: ServerError.self) {
            try await cache.entry(source: source, kind: .questionnaire, content: String(repeating: "b", count: 64), maximumBytes: 1024) {
                bytes
            }
        }
    }

    @Test
    func sweepRemovesEntriesOfEarlierVersionsAndUnknownKinds() async throws {
        let (cache, provider) = cache()
        let content = ArtifactStore.digest(bytes)
        try await cache.store(bytes, source: source, kind: .questionnaire)
        let current = DerivedArtifactCache.key(source: source, kind: .questionnaire, content: content)
        let earlier = DerivedArtifactCache.key(source: source, kind: .init(name: "questionnaire", version: 0), content: content)
        let unknown = DerivedArtifactCache.key(source: source, kind: .init(name: "retired", version: 1), content: content)
        for key in [earlier, unknown] {
            try await provider.upload(data: bytes, key: key, contentType: "application/octet-stream")
        }
        #expect(try await cache.sweep() == 2)
        #expect(try await provider.keys(prefix: "derived/") == [current])
    }

    @Test
    func deletingTheSourceDeletesItsEntriesOnly() async throws {
        let (cache, provider) = cache()
        let other = String(repeating: "c", count: 64)
        try await cache.store(bytes, source: source, kind: .questionnaire)
        try await cache.store(bytes, source: other, kind: .questionnaire)
        try await cache.deleteSource(source)
        let kept = DerivedArtifactCache.key(source: other, kind: .questionnaire, content: ArtifactStore.digest(bytes))
        #expect(try await provider.keys(prefix: "derived/") == [kept])
    }
}
