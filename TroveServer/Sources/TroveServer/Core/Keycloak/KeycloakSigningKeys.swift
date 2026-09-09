//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import JWTKit


/// A bounded, issuer-scoped trust cache. Successful refresh replaces rather than merges keys.
actor KeycloakSigningKeys: TokenKeyProvider {
    enum RefreshError: Error, Equatable {
        case invalidConfiguration
        case invalidKeySet
        case unknownKey
        case unavailable
    }

    private struct Snapshot: Sendable {
        let collection: JWTKeyCollection
        let identifiers: Set<String>
        let expiresAt: ContinuousClock.Instant
    }

    private struct Refresh: Sendable {
        let id: UUID
        let task: Task<Snapshot, any Error>
    }

    private let lifetime: Duration
    private let cooldown: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let fetch: @Sendable () async throws -> JWKS
    private var snapshot: Snapshot
    private var nextRefreshAt: ContinuousClock.Instant
    private var refresh: Refresh?

    init(
        initialJWKS: JWKS,
        lifetime: Duration = .seconds(300),
        cooldown: Duration = .seconds(30),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
        fetch: @escaping @Sendable () async throws -> JWKS
    ) async throws {
        guard lifetime > .zero, lifetime <= .seconds(300), cooldown > .zero, cooldown <= lifetime else {
            throw RefreshError.invalidConfiguration
        }
        self.lifetime = lifetime
        self.cooldown = cooldown
        self.now = now
        self.fetch = fetch
        let startedAt = now()
        self.nextRefreshAt = startedAt.advanced(by: cooldown)
        self.snapshot = try await Self.makeSnapshot(initialJWKS, expiresAt: startedAt.advanced(by: lifetime))
    }

    private static func makeSnapshot(_ jwks: JWKS, expiresAt: ContinuousClock.Instant) async throws -> Snapshot {
        guard jwks.keys.count <= 32 else {
            throw RefreshError.invalidKeySet
        }
        let collection = JWTKeyCollection()
        var identifiers = Set<String>()
        for key in jwks.keys where key.algorithm == .rs256 {
            guard key.keyType == .rsa,
                  let identifier = key.keyIdentifier?.string, !identifier.isEmpty, identifier.utf8.count <= 256,
                  identifiers.insert(identifier).inserted,
                  let modulus = key.modulus, !modulus.isEmpty, modulus.utf8.count <= 1_368,
                  let exponent = key.exponent, !exponent.isEmpty, exponent.utf8.count <= 24,
                  key.privateExponent == nil, key.prime1 == nil, key.prime2 == nil else {
                throw RefreshError.invalidKeySet
            }
            try await collection.add(jwk: key)
            let algorithm = try await collection.getKey(for: .init(string: identifier), alg: "RS256")
            guard algorithm.name == "RS256" else {
                throw RefreshError.invalidKeySet
            }
        }
        // An empty authoritative set revokes all keys; it must not preserve old trust.
        return Snapshot(collection: collection, identifiers: identifiers, expiresAt: expiresAt)
    }

    func keys(for identifier: String) async throws -> JWTKeyCollection {
        try Task.checkCancellation()
        guard !identifier.isEmpty, identifier.utf8.count <= 256 else {
            throw RefreshError.unknownKey
        }
        if snapshot.expiresAt > now(), snapshot.identifiers.contains(identifier) {
            return snapshot.collection
        }
        guard refresh != nil || now() >= nextRefreshAt else {
            throw snapshot.expiresAt <= now() ? RefreshError.unavailable : RefreshError.unknownKey
        }
        try await refreshSnapshot()
        try Task.checkCancellation()
        // Another waiter may have replaced the snapshot while this caller was suspended.
        guard snapshot.expiresAt > now() else {
            throw RefreshError.unavailable
        }
        guard snapshot.identifiers.contains(identifier) else {
            throw RefreshError.unknownKey
        }
        return snapshot.collection
    }

    private func refreshSnapshot() async throws {
        let pending: Refresh
        if let refresh {
            pending = refresh
        } else {
            let startedAt = now()
            nextRefreshAt = startedAt.advanced(by: cooldown)
            let expiresAt = startedAt.advanced(by: lifetime)
            // This shared operation has an independent lifetime: one canceled request must
            // not cancel verification for other waiters. Its trusted HTTP fetch has a deadline.
            let task = Task { @concurrent [fetch] in
                let jwks = try await fetch()
                try Task.checkCancellation()
                return try await Self.makeSnapshot(jwks, expiresAt: expiresAt)
            }
            pending = Refresh(id: UUID(), task: task)
            refresh = pending
        }
        do {
            let replacement = try await pending.task.value
            if refresh?.id == pending.id {
                snapshot = replacement
                refresh = nil
            }
        } catch {
            if refresh?.id == pending.id {
                refresh = nil
            }
            // A failure cannot extend the old snapshot's expiry or reset the cooldown.
            throw RefreshError.unavailable
        }
    }

    deinit {
        refresh?.task.cancel()
    }
}
