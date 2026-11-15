//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Uses Google Health's stable healthUserId, without requiring unrelated OpenID or profile scopes.
struct GoogleHealthAuthorizationClient: ProviderAuthorizationClient {
    private struct Identity: Decodable { let healthUserId: String }

    let transport: ProviderHTTPTransport
    let secrets: ProviderApplicationSecrets

    func exchange(registration: ProviderRegistration, code: String, redirect: URL, verifier: String?) async throws -> ProviderCredentials {
        guard registration.provider == .googleHealthAPI, registration.supportsPKCE, let verifier,
              (43...128).contains(verifier.utf8.count) else { throw ProviderFailure.invalidConfiguration }
        return try await token(
            registration,
            fields: [
                "grant_type": "authorization_code", "code": code, "redirect_uri": redirect.absoluteString, "code_verifier": verifier
            ],
            prior: nil
        )
    }

    func refresh(registration: ProviderRegistration, credentials: ProviderCredentials) async throws -> ProviderCredentials {
        try await token(registration, fields: ["grant_type": "refresh_token", "refresh_token": credentials.refreshToken], prior: credentials)
    }

    private func token(
        _ registration: ProviderRegistration, fields: [String: String], prior: ProviderCredentials?
    ) async throws -> ProviderCredentials {
        guard registration.provider == .googleHealthAPI else { throw ProviderFailure.invalidConfiguration }
        var fields = fields
        fields["client_id"] = registration.clientID
        fields["client_secret"] = try secrets.secret(for: registration.id)
        let bytes = try await transport.send(.googleToken, ProviderHTTPTransport.form(fields), nil, 65_536)
        let response = try ProviderOAuthResponse.decode(bytes)
        let identityBytes = try await transport.send(.googleIdentity, Data(), response.accessToken, 16_384)
        guard let identity = try? JSONDecoder().decode(Identity.self, from: identityBytes),
              (1...63).contains(identity.healthUserId.utf8.count), identity.healthUserId.utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
              }) else { throw ProviderFailure.ambiguousAccount }
        guard prior.map({ $0.accountID == identity.healthUserId }) ?? true else { throw ProviderFailure.ambiguousAccount }
        return try response.credentials(accountID: identity.healthUserId, prior: prior, registration: registration)
    }
}
