//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import AppAuth
import Foundation
import Testing
@testable import Trove


@Suite(.timeLimit(.minutes(1)))
struct KeycloakAuthStateBindingTests {
    @Test(arguments: ["auth", "registrations"])
    func archivedStateRetainsMatchingConfiguration(endpoint: String) throws {
        let configuration = try configuration()
        let response = response(configuration, endpoint: endpoint)
        let state = try archivedState(authorization: response, tokenSource: response)
        try KeycloakAuthStateBinding.validate(state, configuration: configuration)
    }

    @Test(arguments: [
        "authorization-issuer", "authorization-client", "redirect", "token-issuer", "token-client", "token-endpoint",
        "identity-issuer", "identity-audience", "missing-identity"
    ])
    func archivedStateCannotCrossConfiguration(change: String) throws {
        let configuration = try configuration()
        let otherIssuer = try #require(URL(string: "https://other.example.test/realms/trove"))
        let otherRedirect = try #require(URL(string: "other-app:/callback"))
        let authorizationConfiguration = KeycloakConfiguration(
            issuer: change == "authorization-issuer" ? otherIssuer : configuration.issuer,
            clientID: change == "authorization-client" ? "another-client" : configuration.clientID,
            redirectURI: change == "redirect" ? otherRedirect : configuration.redirectURI
        )
        let tokenConfiguration = KeycloakConfiguration(
            issuer: change == "token-issuer" ? otherIssuer : configuration.issuer,
            clientID: change == "token-client" ? "another-client" : configuration.clientID,
            redirectURI: configuration.redirectURI
        )
        let authorization = response(authorizationConfiguration)
        let tokenSource = response(
            tokenConfiguration,
            tokenEndpoint: change == "token-endpoint" ? otherIssuer.appendingPathComponent("token") : nil
        )
        let state = try archivedState(
            authorization: authorization,
            tokenSource: tokenSource,
            identityIssuer: change == "identity-issuer" ? otherIssuer : nil,
            identityAudience: change == "identity-audience" ? "another-client" : nil,
            missingIdentity: change == "missing-identity"
        )
        #expect(throws: KeycloakAccountError.self) {
            try KeycloakAuthStateBinding.validate(state, configuration: configuration)
        }
    }

    @Test
    func authorizationWithoutTokenCannotBeRestored() throws {
        let configuration = try configuration()
        let state = OIDAuthState(authorizationResponse: response(configuration))
        #expect(throws: KeycloakAccountError.self) {
            try KeycloakAuthStateBinding.validate(state, configuration: configuration)
        }
    }

    @Test
    func archivedExpiredTokensRemainUsableForLocalAccountRestoration() throws {
        let configuration = try configuration()
        let response = response(configuration)
        let state = try archivedState(authorization: response, tokenSource: response, expired: true)
        #expect(try #require(state.lastTokenResponse?.accessTokenExpirationDate) < .now)
        try KeycloakAuthStateBinding.validate(state, configuration: configuration)
    }

    @Test
    func networkFailureDoesNotInvalidateTheRetainedAccount() throws {
        let configuration = try configuration()
        let response = response(configuration)
        let state = try archivedState(authorization: response, tokenSource: response, expired: true)
        state.update(with: Optional<OIDTokenResponse>.none, error: URLError(.notConnectedToInternet))
        try KeycloakAuthStateBinding.validate(state, configuration: configuration)
    }

    @Test
    func confirmedAuthorizationFailureCannotRestoreEvenWithRetainedIdentityClaims() throws {
        let configuration = try configuration()
        let response = response(configuration)
        let state = try archivedState(authorization: response, tokenSource: response)
        state.update(withAuthorizationError: NSError(domain: OIDOAuthTokenErrorDomain, code: -1))
        let data = try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
        let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data)
        let restored = try #require(decoded)
        #expect(restored.lastTokenResponse?.idToken != nil)
        #expect(throws: KeycloakAccountError.self) { try KeycloakAuthStateBinding.validate(restored, configuration: configuration) }
    }

    @Test
    @MainActor
    func sdkAuthorizationChangeIsObservedEvenWhenItsCallingTaskWasCancelled() async throws {
        let configuration = try configuration()
        let response = response(configuration)
        let state = try archivedState(authorization: response, tokenSource: response)
        let changes = AsyncStream<Void>.makeStream()
        let observer = KeycloakAuthStateObserver {
            #expect(!state.isAuthorized)
            changes.continuation.yield(())
            changes.continuation.finish()
        }
        state.stateChangeDelegate = observer
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            state.update(withAuthorizationError: NSError(domain: OIDOAuthTokenErrorDomain, code: -1))
        }
        await task.value
        var notifications = 0
        for await _ in changes.stream { notifications += 1 }
        #expect(notifications == 1)
        withExtendedLifetime(observer) {}
    }

    private func configuration() throws -> KeycloakConfiguration {
        KeycloakConfiguration(
            issuer: try #require(URL(string: "https://identity.example.test/realms/trove")),
            clientID: "trove-ios",
            redirectURI: try #require(URL(string: "trove:/callback"))
        )
    }

    private func response(
        _ configuration: KeycloakConfiguration,
        endpoint: String = "auth",
        tokenEndpoint: URL? = nil
    ) -> OIDAuthorizationResponse {
        let service = OIDServiceConfiguration(
            authorizationEndpoint: configuration.issuer.appendingPathComponent("protocol/openid-connect/\(endpoint)"),
            tokenEndpoint: tokenEndpoint ?? configuration.issuer.appendingPathComponent("protocol/openid-connect/token"),
            issuer: configuration.issuer
        )
        let request = OIDAuthorizationRequest(
            configuration: service,
            clientId: configuration.clientID,
            scopes: [OIDScopeOpenID],
            redirectURL: configuration.redirectURI,
            responseType: OIDResponseTypeCode,
            additionalParameters: nil
        )
        // AppAuth's Objective-C generic requires NSObject and NSCopying values.
        // swiftlint:disable:next legacy_objc_type
        return OIDAuthorizationResponse(request: request, parameters: ["code": "synthetic-code" as NSString])
    }

    private func archivedState(
        authorization: OIDAuthorizationResponse,
        tokenSource: OIDAuthorizationResponse,
        identityIssuer: URL? = nil,
        identityAudience: String? = nil,
        missingIdentity: Bool = false,
        expired: Bool = false
    ) throws -> OIDAuthState {
        let request = try #require(tokenSource.tokenExchangeRequest())
        let issuer = try #require(identityIssuer ?? request.configuration.issuer)
        let idToken = try syntheticIDToken(issuer: issuer, clientID: identityAudience ?? request.clientID)
        var parameters: [String: any NSCopying & NSObjectProtocol] = [
            // swiftlint:disable:next legacy_objc_type
            "access_token": "synthetic-token" as NSString,
            // swiftlint:disable:next legacy_objc_type
            "token_type": "Bearer" as NSString,
            // swiftlint:disable:next legacy_objc_type
            "id_token": idToken as NSString
        ]
        if missingIdentity {
            parameters.removeValue(forKey: "id_token")
        }
        if expired {
            // A real AppAuth token response with an already elapsed lifetime, without a network request.
            // swiftlint:disable:next legacy_objc_type
            parameters["expires_in"] = NSNumber(value: -3600)
        }
        let token = OIDTokenResponse(request: request, parameters: parameters)
        let state = OIDAuthState(authorizationResponse: authorization, tokenResponse: token)
        let data = try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
        let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data)
        return try #require(decoded)
    }

    private func syntheticIDToken(issuer: URL, clientID: String) throws -> String {
        // Only AppAuth's archived configuration/claim parser is under test, not signature verification.
        let claims: [String: Any] = [
            "iss": issuer.absoluteString, "sub": "synthetic-participant", "aud": clientID,
            "iat": 1_700_000_000, "exp": 4_000_000_000
        ]
        let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256"])
        let payload = try JSONSerialization.data(withJSONObject: claims)
        return [header, payload, Data("synthetic-signature".utf8)]
            .map {
                $0.base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
            }
            .joined(separator: ".")
    }
}
