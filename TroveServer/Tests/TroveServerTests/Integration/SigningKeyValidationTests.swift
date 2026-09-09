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


struct SigningKeyValidationTests {
    enum InvalidSet: String, CaseIterable {
        case privateExponent
        case firstPrime
        case secondPrime
        case missingIdentifier
        case oversizedIdentifier
        case missingModulus
        case malformedModulus
        case oversizedModulus
        case oversizedExponent
        case wrongKeyType

        func replacing(_ valid: JWK) -> JWKS {
            var key = valid
            switch self {
            case .privateExponent: key.privateExponent = "AQAB"
            case .firstPrime: key.prime1 = "AQAB"
            case .secondPrime: key.prime2 = "AQAB"
            case .missingIdentifier: key.keyIdentifier = nil
            case .oversizedIdentifier: key.keyIdentifier = .init(string: String(repeating: "x", count: 257))
            case .missingModulus: key.modulus = nil
            case .malformedModulus: key.modulus = "!"
            case .oversizedModulus: key.modulus = String(repeating: "A", count: 1_369)
            case .oversizedExponent: key.exponent = String(repeating: "A", count: 25)
            case .wrongKeyType: key.keyType = .ecdsa
            }
            return .init(keys: [key])
        }
    }

    @Test(arguments: InvalidSet.allCases)
    func malformedTrustCannotBootstrapOrReplaceExpiredTrust(invalid: InvalidSet) async throws {
        let original = try SigningKeyFixtures.SigningKey(identifier: "original")
        let invalidSet = invalid.replacing(original.jwk)
        await #expect(throws: (any Error).self) {
            try await KeycloakSigningKeys(initialJWKS: invalidSet) { invalidSet }
        }
        let source = SigningKeyFixtures.Source([.success(invalidSet)])
        let clock = SigningKeyFixtures.Clock()
        let keys = try await KeycloakSigningKeys(initialJWKS: .init(keys: [original.jwk]), now: clock.now) {
            try await source.fetch()
        }
        clock.advance(by: .seconds(300))
        await #expect(throws: KeycloakSigningKeys.RefreshError.unavailable) {
            try await keys.keys(for: "original")
        }
        await #expect(throws: KeycloakSigningKeys.RefreshError.unavailable) {
            try await keys.keys(for: "another-key")
        }
        #expect(await source.calls == 1)
    }

    @Test(arguments: [JWK.Algorithm.rs512, .rsaOAEP, nil])
    func unsupportedAlgorithmsCannotBecomeSigningKeys(algorithm: JWK.Algorithm?) async throws {
        let signingKey = try SigningKeyFixtures.SigningKey(identifier: "untrusted")
        var key = signingKey.jwk
        key.algorithm = algorithm
        let keys = try await KeycloakSigningKeys(initialJWKS: .init(keys: [key])) {
            Issue.record("Unsupported key triggered refresh during cooldown")
            return .init(keys: [])
        }
        await #expect(throws: KeycloakSigningKeys.RefreshError.unknownKey) {
            try await keys.keys(for: "untrusted")
        }
    }

    @Test
    func duplicateKeyIdentifiersCannotEstablishTrust() async throws {
        let signingKey = try SigningKeyFixtures.SigningKey(identifier: "duplicate")
        await #expect(throws: KeycloakSigningKeys.RefreshError.invalidKeySet) {
            try await KeycloakSigningKeys(initialJWKS: .init(keys: [signingKey.jwk, signingKey.jwk])) {
                .init(keys: [])
            }
        }
    }

    @Test
    func keyCountIsBoundedEvenWithUniqueIdentifiers() async throws {
        let signingKey = try SigningKeyFixtures.SigningKey(identifier: "original")
        let keys = (0..<33).map { index in
            var copy = signingKey.jwk
            copy.keyIdentifier = .init(string: "key-\(index)")
            return copy
        }
        await #expect(throws: KeycloakSigningKeys.RefreshError.invalidKeySet) {
            try await KeycloakSigningKeys(initialJWKS: .init(keys: keys)) { .init(keys: []) }
        }
    }
}
