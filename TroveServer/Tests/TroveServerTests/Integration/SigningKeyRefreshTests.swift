//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import JWTKit
import Testing
@testable import TroveServer


struct SigningKeyRefreshTests {
    @Test
    func rotationReplacesRatherThanMergesTrust() async throws {
        let original = try SigningKeyFixtures.SigningKey(identifier: "original")
        let replacement = try SigningKeyFixtures.SigningKey(identifier: "replacement")
        let source = SigningKeyFixtures.Source([.success(.init(keys: [replacement.jwk]))])
        let clock = SigningKeyFixtures.Clock()
        let keys = try await KeycloakSigningKeys(initialJWKS: .init(keys: [original.jwk]), now: clock.now) {
            try await source.fetch()
        }
        _ = try await keys.keys(for: "original")
        #expect(await source.calls == 0)
        clock.advance(by: .seconds(30))
        let collection = try await keys.keys(for: "replacement")
        let payload = try await collection.verify(replacement.token(), as: KeycloakJWTPayload.self)
        #expect(payload.sub.value == "refresh-participant")
        await #expect(throws: KeycloakSigningKeys.RefreshError.unknownKey) {
            try await keys.keys(for: "original")
        }
        #expect(await source.calls == 1)
    }

    @Test
    func expiredTrustFailsClosedAndFailureIsRateLimited() async throws {
        let original = try SigningKeyFixtures.SigningKey(identifier: "original")
        let source = SigningKeyFixtures.Source([.failure(.offline), .success(.init(keys: [original.jwk]))])
        let clock = SigningKeyFixtures.Clock()
        let keys = try await KeycloakSigningKeys(initialJWKS: .init(keys: [original.jwk]), now: clock.now) {
            try await source.fetch()
        }
        clock.advance(by: .seconds(300))
        await #expect(throws: KeycloakSigningKeys.RefreshError.unavailable) {
            try await keys.keys(for: "original")
        }
        await #expect(throws: KeycloakSigningKeys.RefreshError.unavailable) {
            try await keys.keys(for: "different-unknown-key")
        }
        #expect(await source.calls == 1)
        clock.advance(by: .seconds(30))
        _ = try await keys.keys(for: "original")
        #expect(await source.calls == 2)
    }

    @Test
    func emptyAuthoritativeSetRevokesAllKeys() async throws {
        let original = try SigningKeyFixtures.SigningKey(identifier: "original")
        let source = SigningKeyFixtures.Source([.success(.init(keys: []))])
        let clock = SigningKeyFixtures.Clock()
        let keys = try await KeycloakSigningKeys(initialJWKS: .init(keys: [original.jwk]), now: clock.now) {
            try await source.fetch()
        }
        clock.advance(by: .seconds(300))
        await #expect(throws: KeycloakSigningKeys.RefreshError.unknownKey) {
            try await keys.keys(for: "original")
        }
        await #expect(throws: KeycloakSigningKeys.RefreshError.unknownKey) {
            try await keys.keys(for: "original")
        }
        #expect(await source.calls == 1)
    }

    @Test
    func concurrentUnknownKeysShareOneRefresh() async throws {
        let replacement = try SigningKeyFixtures.SigningKey(identifier: "replacement")
        let gate = SigningKeyFixtures.Gate()
        let clock = SigningKeyFixtures.Clock()
        let keys = try await KeycloakSigningKeys(initialJWKS: .init(keys: []), now: clock.now) { try await gate.fetch() }
        clock.advance(by: .seconds(30))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask { _ = try await keys.keys(for: "replacement") }
            }
            await gate.waitForFetch()
            try await gate.complete(with: .success(.init(keys: [replacement.jwk])))
            try await group.waitForAll()
        }
        #expect(await gate.calls == 1)
    }

    @Test
    func canceledWaiterDoesNotCancelSharedRefresh() async throws {
        let replacement = try SigningKeyFixtures.SigningKey(identifier: "replacement")
        let token = try await replacement.token()
        let gate = SigningKeyFixtures.Gate()
        let clock = SigningKeyFixtures.Clock()
        let keys = try await KeycloakSigningKeys(initialJWKS: .init(keys: []), now: clock.now) { try await gate.fetch() }
        let middleware = AuthMiddleware(
            keyProvider: keys,
            tokenPolicy: try .init(issuer: TestApp.issuer, apiAudience: TestApp.apiAudience),
            researcherRole: TestApp.researcherRole,
            participantRole: TestApp.participantRole,
            logger: .init(label: "SigningKeyRefreshTests"),
            auditConfiguration: try .init(applicationRevision: nil)
        )
        clock.advance(by: .seconds(30))
        let canceled = Task {
            try await middleware.intercept(
                .init(method: .get, scheme: "https", authority: "api.example.test", path: "/", headerFields: [.authorization: "Bearer \(token)"]),
                body: nil,
                metadata: .init(),
                operationID: "protected"
            ) { _, _, _ in
                Issue.record("Canceled request reached the protected handler")
                return (.init(status: .noContent), nil)
            }
        }
        await gate.waitForFetch()
        canceled.cancel()
        let healthy = Task { try await keys.keys(for: "replacement") }
        try await gate.complete(with: .success(.init(keys: [replacement.jwk])))
        await #expect(throws: CancellationError.self) { try await canceled.value }
        _ = try await healthy.value
        #expect(await gate.calls == 1)
    }

    @Test
    func slowCompletionCannotExtendSnapshotExpiry() async throws {
        let replacement = try SigningKeyFixtures.SigningKey(identifier: "replacement")
        let gate = SigningKeyFixtures.Gate()
        let clock = SigningKeyFixtures.Clock()
        let keys = try await KeycloakSigningKeys(initialJWKS: .init(keys: []), now: clock.now) { try await gate.fetch() }
        clock.advance(by: .seconds(30))
        let request = Task { try await keys.keys(for: "replacement") }
        await gate.waitForFetch()
        clock.advance(by: .seconds(300))
        try await gate.complete(with: .success(.init(keys: [replacement.jwk])))
        await #expect(throws: KeycloakSigningKeys.RefreshError.unavailable) { try await request.value }
    }
}
