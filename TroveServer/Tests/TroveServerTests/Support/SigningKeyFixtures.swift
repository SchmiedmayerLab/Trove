//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import CryptoExtras
import Foundation
import JWTKit
import Synchronization
import Testing
@testable import TroveServer


enum SigningKeyFixtures {
    enum Failure: Error {
        case offline
        case overlappingFetch
    }

    final class Clock: Sendable {
        private let instant = Mutex(ContinuousClock().now)

        func now() -> ContinuousClock.Instant {
            instant.withLock { $0 }
        }

        func advance(by duration: Duration) {
            instant.withLock { $0 = $0.advanced(by: duration) }
        }
    }

    actor Source {
        private var responses: [Result<JWKS, Failure>]
        private(set) var calls = 0

        init(_ responses: [Result<JWKS, Failure>]) {
            self.responses = responses
        }

        func fetch() throws -> JWKS {
            calls += 1
            guard !responses.isEmpty else {
                throw Failure.offline
            }
            return try responses.removeFirst().get()
        }
    }

    actor Gate {
        private var pending: CheckedContinuation<JWKS, any Error>?
        private var started: [CheckedContinuation<Void, Never>] = []
        private(set) var calls = 0

        func fetch() async throws -> JWKS {
            calls += 1
            guard pending == nil else {
                throw Failure.overlappingFetch
            }
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                started.forEach { $0.resume() }
                started.removeAll()
            }
        }

        func waitForFetch() async {
            guard calls == 0 else {
                return
            }
            await withCheckedContinuation { started.append($0) }
        }

        func complete(with result: Result<JWKS, Failure>) throws {
            let continuation = try #require(pending)
            pending = nil
            continuation.resume(with: result.mapError { $0 as any Error })
        }
    }

    struct SigningKey: Sendable {
        let jwk: JWK
        let privateKey: JWTKit.Insecure.RSA.PrivateKey
        let identifier: String

        init(identifier: String) throws {
            self.identifier = identifier
            self.privateKey = try JWTKit.Insecure.RSA.PrivateKey(backing: _RSA.Signing.PrivateKey(keySize: .bits2048))
            let values = try privateKey.publicKey.getKeyPrimitives()
            self.jwk = .rsa(
                .rs256,
                identifier: .init(string: identifier),
                modulus: SigningKeyFixtures.base64URL(values.modulus),
                exponent: SigningKeyFixtures.base64URL(values.publicExponent)
            )
        }

        func token() async throws -> String {
            let collection = JWTKeyCollection()
            await collection.add(rsa: privateKey, digestAlgorithm: .sha256, kid: .init(string: identifier))
            let payload = KeycloakJWTPayload(
                iss: .init(value: TestApp.issuer),
                aud: .init(value: [TestApp.apiAudience]),
                sub: .init(value: "refresh-participant"),
                exp: .init(value: Date().addingTimeInterval(3_600)),
                nbf: nil,
                email: "fixture@example.test",
                roles: [TestApp.participantRole],
                groups: []
            )
            return try await collection.sign(payload, kid: .init(string: identifier))
        }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
