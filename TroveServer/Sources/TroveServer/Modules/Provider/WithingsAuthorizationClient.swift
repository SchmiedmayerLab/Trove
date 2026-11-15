//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Withings' documented confidential-client flow. Account identity comes from the token endpoint's userid.
struct WithingsAuthorizationClient: ProviderAuthorizationClient {
    private struct Body: Decodable {
        enum CodingKeys: String, CodingKey {
            case userid, scope
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case tokenType = "token_type"
        }

        let userid: Int64
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int64
        let scope: String
        let tokenType: String
    }

    private struct Response: Decodable {
        let status: Int
        let body: Body?
    }

    let transport: ProviderHTTPTransport
    let secrets: ProviderApplicationSecrets

    func exchange(registration: ProviderRegistration, code: String, redirect: URL, verifier: String?) async throws -> ProviderCredentials {
        guard verifier == nil, !registration.supportsPKCE else { throw ProviderFailure.invalidConfiguration }
        return try await token(registration, fields: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirect.absoluteString
        ])
    }

    func refresh(registration: ProviderRegistration, credentials: ProviderCredentials) async throws -> ProviderCredentials {
        let result = try await token(registration, fields: ["grant_type": "refresh_token", "refresh_token": credentials.refreshToken])
        guard result.accountID == credentials.accountID else { throw ProviderFailure.ambiguousAccount }
        return result
    }

    private func token(_ registration: ProviderRegistration, fields: [String: String]) async throws -> ProviderCredentials {
        guard registration.provider == .withings else { throw ProviderFailure.invalidConfiguration }
        var fields = fields
        fields["action"] = "requesttoken"
        fields["client_id"] = registration.clientID
        fields["client_secret"] = try secrets.secret(for: registration.id)
        let bytes = try await transport.send(.withingsToken, ProviderHTTPTransport.form(fields), nil, 65_536)
        guard let response = try? JSONDecoder().decode(Response.self, from: bytes), response.status == 0,
              let body = response.body, body.userid > 0, (1...31_536_000).contains(body.expiresIn),
              body.tokenType.lowercased() == "bearer" else { throw ProviderFailure.reauthorizationRequired }
        let credentials = ProviderCredentials(
            accessToken: body.accessToken,
            refreshToken: body.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(body.expiresIn)),
            scopes: Set(body.scope.split { $0 == "," || $0 == " " }.map(String.init)),
            accountID: String(body.userid)
        )
        try credentials.validate(requiredScopes: registration.scopes, at: Date())
        return credentials
    }
}
