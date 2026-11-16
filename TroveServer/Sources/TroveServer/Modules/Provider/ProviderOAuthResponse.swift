//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Standard token response fields. Omitted scope retains the requested grant under OAuth 2.0 section 5.1.
struct ProviderOAuthResponse: Decodable {
    enum CodingKeys: String, CodingKey {
        case scope
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }

    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int64
    let tokenType: String
    let scope: String?

    static func decode(_ bytes: Data) throws -> Self {
        guard let response = try? JSONDecoder().decode(Self.self, from: bytes),
              response.tokenType.lowercased() == "bearer", (1...31_536_000).contains(response.expiresIn),
              !response.accessToken.isEmpty, response.accessToken.utf8.count <= 16_384,
              response.accessToken.utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                      || [45, 46, 95, 126, 43, 47, 61].contains($0)
              }) else {
            throw ProviderFailure.reauthorizationRequired
        }
        return response
    }

    func credentials(accountID: String, prior: ProviderCredentials?, registration: ProviderRegistration) throws -> ProviderCredentials {
        // Oura refresh tokens rotate on every exchange; Google may retain the previously issued refresh token.
        guard let refreshToken = refreshToken ?? (registration.provider == .googleHealthAPI ? prior?.refreshToken : nil) else {
            throw ProviderFailure.reauthorizationRequired
        }
        let scopes = scope.map { Set($0.split(separator: " ").map(String.init)) } ?? prior?.scopes ?? registration.scopes
        let credentials = ProviderCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            scopes: scopes,
            accountID: accountID
        )
        try credentials.validate(requiredScopes: registration.scopes, at: Date())
        return credentials
    }
}
