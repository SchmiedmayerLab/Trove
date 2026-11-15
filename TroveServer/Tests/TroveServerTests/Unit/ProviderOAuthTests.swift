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


struct ProviderOAuthTests {
    private actor Upstream {
        let provider: ConnectedProvider
        let rotated: Bool
        let account: String
        var calls: [ProviderHTTPTransport.Endpoint] = []

        init(provider: ConnectedProvider, rotated: Bool = true, account: String = "source-account") {
            self.provider = provider
            self.rotated = rotated
            self.account = account
        }

        func send(_ endpoint: ProviderHTTPTransport.Endpoint, body: Data, bearer: String?, limit: Int) throws -> Data {
            calls.append(endpoint)
            if endpoint == .ouraToken || endpoint == .googleToken {
                #expect(bearer == nil)
                let form = try #require(String(data: body, encoding: .utf8))
                #expect(form.contains("client_secret=synthetic-secret"))
                #expect(form.contains("grant_type="))
                var value: [String: Any] = ["access_token": "new-access", "token_type": "Bearer", "expires_in": 3600]
                if rotated { value["refresh_token"] = "new-refresh" }
                return try JSONSerialization.data(withJSONObject: value)
            }
            #expect(endpoint == (provider == .oura ? .ouraIdentity : .googleIdentity))
            #expect(bearer == "new-access" && body.isEmpty && limit == 16_384)
            return try JSONSerialization.data(withJSONObject: [provider == .oura ? "id" : "healthUserId": account])
        }
    }

    @Test("OAuth exchange verifies the provider account with the acquired token", arguments: [ConnectedProvider.oura, .googleHealthAPI])
    func verifiedAccount(_ provider: ConnectedProvider) async throws {
        let registration = try Self.registration(provider)
        let upstream = Upstream(provider: provider)
        let client = try Self.client(registration, upstream: upstream)
        let credentials = try await client.exchange(
            registration: registration, code: "synthetic-code", redirect: registration.redirect(id: "native"),
            verifier: String(repeating: "x", count: 43)
        )
        #expect(credentials.accountID == "source-account")
        #expect(credentials.scopes == registration.scopes)
        #expect(credentials.refreshToken == "new-refresh")
        #expect(await upstream.calls.count == 2)
        await #expect(throws: ProviderFailure.invalidConfiguration) {
            try await client.exchange(registration: registration, code: "code", redirect: registration.redirect(id: "native"), verifier: nil)
        }
        #expect(await upstream.calls.count == 2)
    }

    @Test("Refresh preserves Google tokens when omitted and requires Oura rotation", arguments: [ConnectedProvider.oura, .googleHealthAPI])
    func refreshSemantics(_ provider: ConnectedProvider) async throws {
        let registration = try Self.registration(provider)
        let upstream = Upstream(provider: provider, rotated: false)
        let client = try Self.client(registration, upstream: upstream)
        let prior = Self.credentials(registration)
        if provider == .oura {
            await #expect(throws: ProviderFailure.reauthorizationRequired) {
                try await client.refresh(registration: registration, credentials: prior)
            }
        } else {
            let refreshed = try await client.refresh(registration: registration, credentials: prior)
            #expect(refreshed.refreshToken == prior.refreshToken)
            #expect(refreshed.scopes == prior.scopes)
        }
    }

    @Test("A successful refresh cannot silently replace the verified source account", arguments: [ConnectedProvider.oura, .googleHealthAPI])
    func accountChangeFenced(_ provider: ConnectedProvider) async throws {
        let registration = try Self.registration(provider)
        let client = try Self.client(registration, upstream: Upstream(provider: provider, account: "another-account"))
        await #expect(throws: ProviderFailure.ambiguousAccount) {
            try await client.refresh(registration: registration, credentials: Self.credentials(registration))
        }
    }

    @Test("Token endpoint scope reductions remain authoritative")
    func narrowedScopeCannotBecomeRequestedScope() throws {
        let registration = try Self.registration(.oura)
        let bytes = try JSONSerialization.data(withJSONObject: [
            "access_token": "new-access", "refresh_token": "new-refresh", "token_type": "bearer", "expires_in": 3600, "scope": "personal"
        ])
        let response = try ProviderOAuthResponse.decode(bytes)
        #expect(throws: ProviderFailure.scopeLost) { try response.credentials(accountID: "source-account", prior: nil, registration: registration) }
    }

    private static func registration(_ provider: ConnectedProvider) throws -> ProviderRegistration {
        .init(
            id: UUID(), provider: provider, displayName: "Synthetic", controller: "test-controller", region: "test-region",
            clientID: "synthetic-client", redirects: [.init(id: "native", uri: try #require(URL(string: "https://example.test/oauth/callback")))],
            scopes: provider == .oura ? ["personal", "daily"] : ["https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly"],
            sourceTokens: provider == .oura ? ["vO2_max"] : ["weight"], supportsPKCE: true
        )
    }

    private static func client(_ registration: ProviderRegistration, upstream: Upstream) throws -> ProviderAuthorizationRouter {
        try .init(
            transport: .init { endpoint, body, bearer, limit in try await upstream.send(endpoint, body: body, bearer: bearer, limit: limit) },
            secrets: .init([registration.id: "synthetic-secret"])
        )
    }

    private static func credentials(_ registration: ProviderRegistration) -> ProviderCredentials {
        .init(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: Date().addingTimeInterval(60),
              scopes: registration.scopes, accountID: "source-account")
    }
}
