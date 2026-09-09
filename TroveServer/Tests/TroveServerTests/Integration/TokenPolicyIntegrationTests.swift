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
import Testing
@testable import TroveServer
import VaporTesting


struct TokenPolicyIntegrationTests {
    /// Allows intentionally incomplete claims to reach the real verification boundary.
    private struct TokenClaims: JWTPayload {
        var iss: String? = TestApp.issuer
        var aud: KeycloakAudience? = .init(value: [TestApp.apiAudience])
        var sub: String? = "researcher-test-user"
        var exp: Double? = Date().addingTimeInterval(3600).timeIntervalSince1970
        var nbf: Double?
        var email = "test@example.com"
        var roles = [TestApp.researcherRole]
        var groups = ["/Test Group/admin"]

        // Signing invalid test claims is intentional; the server performs validation.
        func verify(using algorithm: some JWTAlgorithm) async throws {}
    }

    @Test
    func identityProviderErrorsContainOnlyOperationAndStatus() {
        #expect(KeycloakError.failedToAuthenticate(statusCode: 401).description
            == "Failed to authenticate with Keycloak (HTTP 401)")
        #expect(KeycloakError.failedToFetchGroups(statusCode: 503).description
            == "Failed to fetch groups from Keycloak (HTTP 503)")
    }

    @Test(arguments: [TestApp.testSecret, TestApp.rotatedTestSecret, TestApp.wrongTestSecret])
    func syntheticSigningKeysSupportAllTestAlgorithms(secret: String) {
        #expect(secret.utf8.count >= 64)
        #expect(Set([TestApp.testSecret, TestApp.rotatedTestSecret, TestApp.wrongTestSecret]).count == 3)
    }

    @Test(arguments: [
        "issuer", "audience", "empty-audience", "subject", "expiration", "future",
        "missing-issuer", "missing-audience", "missing-subject", "missing-expiration"
    ])
    func rejectsInvalidClaims(claim: String) async throws {
        var claims = TokenClaims()
        switch claim {
        case "issuer": claims.iss = "https://foreign.example.test/realms/trove"
        case "audience": claims.aud = .init(value: ["trove-web", "account"])
        case "empty-audience": claims.aud = .init(value: [])
        case "subject": claims.sub = " "
        case "expiration": claims.exp = Date().addingTimeInterval(-3600).timeIntervalSince1970
        case "future": claims.nbf = Date().addingTimeInterval(3600).timeIntervalSince1970
        case "missing-issuer": claims.iss = nil
        case "missing-audience": claims.aud = nil
        case "missing-subject": claims.sub = nil
        default: claims.exp = nil
        }
        let keys = JWTKeyCollection()
        await keys.add(hmac: HMACKey(from: TestApp.testSecret), digestAlgorithm: .sha256)
        let token = try await keys.sign(claims, kid: "test-key")
        try await TestApp.withApp(token: .none) { app, _ in
            try await app.test(.GET, "\(apiBasePath)/groups", beforeRequest: { request in
                request.bearerAuth(token)
            }) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test(arguments: [[TestApp.apiAudience], ["account", TestApp.apiAudience]])
    func acceptsIntendedAudience(audiences: [String]) async throws {
        var claims = TokenClaims()
        claims.aud = .init(value: audiences)
        let keys = JWTKeyCollection()
        await keys.add(hmac: HMACKey(from: TestApp.testSecret), digestAlgorithm: .sha256)
        let token = try await keys.sign(claims, kid: "test-key")
        try await TestApp.withApp(token: .none) { app, _ in
            try await app.test(.GET, "\(apiBasePath)/groups", beforeRequest: { request in
                request.bearerAuth(token)
            }) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test(arguments: [
        ("", "trove-api"), ("not-an-issuer", "trove-api"), (TestApp.issuer, " "),
        ("http://identity.example.test/realms/trove", "trove-api"), (TestApp.issuer, "trove-api ")
    ])
    func rejectsMissingPolicy(issuer: String, audience: String) {
        #expect(throws: (any Error).self) {
            try KeycloakTokenPolicy(issuer: issuer, apiAudience: audience)
        }
    }

    @Test(arguments: ["[]", "null", "123", "{}", "[null]", "[true]"])
    func malformedAudienceThrowsInsteadOfTrapping(json: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(KeycloakAudience.self, from: Data(json.utf8))
        }
    }

    @Test
    func rejectsUnexpectedAlgorithm() async throws {
        let keys = JWTKeyCollection()
        await keys.add(hmac: HMACKey(from: TestApp.testSecret), digestAlgorithm: .sha512)
        let token = try await keys.sign(TokenClaims(), kid: "test-key")
        try await TestApp.withApp(token: .none) { app, _ in
            try await app.test(.GET, "\(apiBasePath)/groups", beforeRequest: { request in
                request.bearerAuth(token)
            }) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func acceptsSeparatelyTrustedRotatedKey() async throws {
        let keys = JWTKeyCollection()
        await keys.add(hmac: HMACKey(from: TestApp.rotatedTestSecret), digestAlgorithm: .sha256, kid: "rotated-test-key")
        let token = try await keys.sign(TokenClaims(), kid: "rotated-test-key")
        try await TestApp.withApp(token: .none) { app, _ in
            try await app.test(.GET, "\(apiBasePath)/groups", beforeRequest: { request in
                request.bearerAuth(token)
            }) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test
    func unknownKeyCannotFallBackToDefaultSigner() async throws {
        let keys = JWTKeyCollection()
        await keys.add(hmac: HMACKey(from: TestApp.testSecret), digestAlgorithm: .sha256)
        let token = try await keys.sign(TokenClaims(), kid: "unknown-key")
        try await TestApp.withApp(token: .none) { app, _ in
            try await app.test(.GET, "\(apiBasePath)/groups", beforeRequest: { request in
                request.bearerAuth(token)
            }) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func productionRS256PolicyUsesPublicKeyAndVerifiedIdentity() async throws {
        let privateKey = try Insecure.RSA.PrivateKey(backing: _RSA.Signing.PrivateKey(keySize: .bits2048))
        let signingKeys = JWTKeyCollection()
        await signingKeys.add(rsa: privateKey, digestAlgorithm: .sha256, kid: "realm-key")
        let token = try await signingKeys.sign(TokenClaims(), kid: "realm-key")
        let verificationKeys = JWTKeyCollection()
        await verificationKeys.add(rsa: privateKey.publicKey, digestAlgorithm: .sha256, kid: "realm-key")
        let middleware = AuthMiddleware(
            keyProvider: FixedTokenKeys(collection: verificationKeys, identifiers: ["realm-key"]),
            tokenPolicy: try .init(issuer: TestApp.issuer, apiAudience: TestApp.apiAudience),
            researcherRole: TestApp.researcherRole,
            participantRole: TestApp.participantRole,
            logger: .init(label: "TokenPolicyIntegrationTests"),
            auditConfiguration: try .init(applicationRevision: nil)
        )
        let (response, _) = try await middleware.intercept(
            .init(method: .get, scheme: "https", authority: "api.example.test", path: "/protected", headerFields: [.authorization: "Bearer \(token)"]),
            body: nil,
            metadata: .init(),
            operationID: "protected"
        ) { _, _, _ in
            let actor = try #require(AuthContext.current)
            #expect(actor.issuer == TestApp.issuer)
            #expect(actor.subject == "researcher-test-user")
            return (.init(status: .noContent), nil)
        }
        #expect(response.status == .noContent)
        #expect(AuthContext.current == nil)
    }
}
