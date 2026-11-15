//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import Testing
@testable import TroveServer
import Vapor


enum ProviderFixture {
    actor Authorization: ProviderAuthorizationClient {
        var exchanges = 0
        var refreshes = 0
        var failExchange = false
        var failRefresh = false
        var accountID = "123"
        var credentialLifetime: TimeInterval = 600

        func setAccount(_ id: String) { accountID = id }
        func setCredentialLifetime(_ seconds: TimeInterval) { credentialLifetime = seconds }
        func setExchangeFailure() { failExchange = true }
        func setRefreshFailure() { failRefresh = true }

        func exchange(registration: ProviderRegistration, code: String, redirect: URL, verifier: String?) async throws -> ProviderCredentials {
            exchanges += 1
            if failExchange { throw ProviderFailure.unavailable }
            return credentials(registration: registration)
        }

        func refresh(registration: ProviderRegistration, credentials: ProviderCredentials) async throws -> ProviderCredentials {
            refreshes += 1
            if failRefresh { throw ProviderFailure.unavailable }
            return self.credentials(registration: registration)
        }

        private func credentials(registration: ProviderRegistration) -> ProviderCredentials {
            .init(
                accessToken: "synthetic-access",
                refreshToken: "synthetic-refresh",
                expiresAt: Date().addingTimeInterval(credentialLifetime),
                scopes: registration.scopes,
                accountID: accountID
            )
        }
    }

    static func registration(
        id: UUID = UUID(), sourceTokens: Set<String> = ["getmeas:1", "getmeas:9+10", "getmeas:11"]
    ) throws -> ProviderRegistration {
        .init(
            id: id,
            provider: .withings,
            displayName: "Synthetic Withings",
            controller: "test-controller",
            region: "test-region",
            clientID: "synthetic-client",
            redirects: [.init(id: "native", uri: try #require(URL(string: "https://example.test/oauth/callback")))],
            scopes: ["user.metrics"],
            sourceTokens: sourceTokens,
            supportsPKCE: false
        )
    }

    static func service(on app: Application, authorization: Authorization) throws -> ProviderConnectionService {
        try .init(
            database: app.db,
            vault: .init(currentKeyID: "synthetic", keys: ["synthetic": SymmetricKey(data: Data(repeating: 0x35, count: 32))]),
            sourceKeyring: TestApp.sourceKeyring(),
            authorization: authorization
        )
    }

    static func state(_ intent: ProviderConnectionService.LinkIntent) throws -> String {
        try #require(URLComponents(url: intent.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
    }
}
