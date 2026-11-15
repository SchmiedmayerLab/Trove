//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Confidential Oura OAuth with S256 and account identity obtained using the resulting bearer token.
struct OuraAuthorizationClient: ProviderAuthorizationClient {
    private struct Identity: Decodable { let id: String }

    let transport: ProviderHTTPTransport
    let secrets: ProviderApplicationSecrets

    func exchange(registration: ProviderRegistration, code: String, redirect: URL, verifier: String?) async throws -> ProviderCredentials {
        guard registration.provider == .oura, registration.supportsPKCE, let verifier,
              (43...128).contains(verifier.utf8.count), registration.scopes.contains("personal") else {
            throw ProviderFailure.invalidConfiguration
        }
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
        guard registration.provider == .oura, registration.scopes.contains("personal") else { throw ProviderFailure.invalidConfiguration }
        var fields = fields
        fields["client_id"] = registration.clientID
        fields["client_secret"] = try secrets.secret(for: registration.id)
        let bytes = try await transport.send(.ouraToken, ProviderHTTPTransport.form(fields), nil, 65_536)
        let response = try ProviderOAuthResponse.decode(bytes)
        let identityBytes = try await transport.send(.ouraIdentity, Data(), response.accessToken, 16_384)
        guard let identity = try? JSONDecoder().decode(Identity.self, from: identityBytes),
              !identity.id.isEmpty, identity.id.utf8.count <= 512 else { throw ProviderFailure.ambiguousAccount }
        guard prior.map({ $0.accountID == identity.id }) ?? true else { throw ProviderFailure.ambiguousAccount }
        return try response.credentials(accountID: identity.id, prior: prior, registration: registration)
    }
}
