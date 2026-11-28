//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Logging


/// A kind of artifact that is expensive to derive from a stored source artifact, such as one Questionnaire extracted
/// from a publication archive.
///
/// To add a kind, declare a `static let` with a new path-safe `name` and version 1, add it to ``registered``, and call
/// ``DerivedArtifactCache/entry(source:kind:content:maximumBytes:derive:)`` where the derived bytes are read. Prefill
/// it with ``DerivedArtifactCache/store(_:source:kind:)`` where the source is created. Increase `version` whenever the
/// derivation changes its output; sweeps then remove the entries of earlier versions.
struct DerivedArtifactKind: Sendable, Hashable {
    /// One Questionnaire's exact bytes, extracted from a publication archive.
    static let questionnaire = Self(name: "questionnaire", version: 1)

    /// Every kind the server reads. Entries of other kinds or versions are unreachable and are swept.
    static let registered: [Self] = [.questionnaire]

    let name: String
    let version: Int
}


/// Derived artifacts in object storage, without a database table: the key carries the ownership.
///
/// An entry's key is `derived/<source-sha256>/<kind>/<version>/<content-sha256>`. Entries are content-addressed, so
/// they never become stale, and every read verifies the content digest; a missing or mismatching entry is derived
/// again and written back. Deleting a source artifact deletes its `derived/<source-sha256>/` prefix. A sweep deletes
/// entries whose kind or version is not registered.
struct DerivedArtifactCache: Sendable {
    static let root = "derived/"
    private static let logger = Logger(label: "trove.derived-artifacts")

    let storage: ObjectStorageService

    static func prefix(source: String) -> String {
        "\(root)\(source)/"
    }

    static func key(source: String, kind: DerivedArtifactKind, content: String) -> String {
        "\(prefix(source: source))\(kind.name)/\(kind.version)/\(content)"
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The entry with the given content digest. On a miss or a digest mismatch, `derive` computes it once and the entry
    /// is written back; derived bytes with another digest are refused.
    func entry(
        source: String, kind: DerivedArtifactKind, content: String, maximumBytes: Int, derive: () async throws -> Data
    ) async throws -> Data {
        guard Self.isDigest(source), Self.isDigest(content) else { throw ServerError.internalServerError("Invalid derived artifact key") }
        let key = Self.key(source: source, kind: kind, content: content)
        do {
            let cached = try await storage.download(key: key, maximumBytes: maximumBytes)
            if ArtifactStore.digest(cached) == content {
                return cached
            }
            Self.logger.warning("Derived artifact does not match its digest; deriving it again", metadata: ["kind": .string(kind.name)])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A missing entry and an unreadable one are both derived again.
            Self.logger.debug("Derived artifact not read", metadata: ["kind": .string(kind.name), "error": .string("\(type(of: error))")])
        }
        let bytes = try await derive()
        guard bytes.count <= maximumBytes, ArtifactStore.digest(bytes) == content else {
            throw ServerError.internalServerError("Derived artifact does not match its digest")
        }
        do {
            try await storage.upload(data: bytes, key: key, contentType: "application/octet-stream")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The verified bytes are returned; the next read derives them again.
            Self.logger.warning("Derived artifact not written", metadata: ["kind": .string(kind.name), "error": .string("\(type(of: error))")])
        }
        return bytes
    }

    /// Writes an entry derived where its source was created.
    func store(_ bytes: Data, source: String, kind: DerivedArtifactKind) async throws {
        guard Self.isDigest(source) else { throw ServerError.internalServerError("Invalid derived artifact key") }
        let key = Self.key(source: source, kind: kind, content: ArtifactStore.digest(bytes))
        try await storage.upload(data: bytes, key: key, contentType: "application/octet-stream")
    }

    /// Deletes every entry derived from a source artifact that is deleted.
    func deleteSource(_ source: String) async throws {
        guard Self.isDigest(source) else { throw ServerError.internalServerError("Invalid derived artifact key") }
        for key in try await storage.keys(prefix: Self.prefix(source: source)) {
            try await storage.delete(key: key)
        }
    }

    /// Deletes up to `limit` entries whose kind and version are not registered, and returns how many it deleted. It lists
    /// every key under `derived/` on each run, and must run from the same build as the servers, whose registered kinds
    /// it compares against.
    func sweep(limit: Int = 1000) async throws -> Int {
        let current = Set(DerivedArtifactKind.registered.map { "\($0.name)/\($0.version)" })
        var deleted = 0
        for key in try await storage.keys(prefix: Self.root) where deleted < limit {
            let parts = key.dropFirst(Self.root.count).split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count != 4 || !current.contains("\(parts[1])/\(parts[2])") else { continue }
            try await storage.delete(key: key)
            deleted += 1
        }
        return deleted
    }
}
