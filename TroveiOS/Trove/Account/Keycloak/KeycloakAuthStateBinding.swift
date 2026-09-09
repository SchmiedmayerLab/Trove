//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import AppAuth
import Foundation


/// Checks persisted request configuration before restoring a session or refreshing its tokens.
enum KeycloakAuthStateBinding {
    static func validate(_ state: OIDAuthState, configuration: KeycloakConfiguration) throws {
        let authorization = state.lastAuthorizationResponse.request
        guard authorization.clientID == configuration.clientID,
              authorization.redirectURL == configuration.redirectURI,
              matches(authorization.configuration, configuration) else {
            throw KeycloakAccountError.notSignedIn
        }
        guard let token = state.lastTokenResponse?.request,
              token.clientID == configuration.clientID,
              matches(token.configuration, configuration) else {
            throw KeycloakAccountError.notSignedIn
        }
        guard let rawIDToken = state.lastTokenResponse?.idToken,
              let idToken = OIDIDToken(idTokenString: rawIDToken),
              idToken.issuer == configuration.issuer,
              (idToken.audience as? [String])?.contains(configuration.clientID) == true else {
            throw KeycloakAccountError.notSignedIn
        }
    }

    private static func matches(_ stored: OIDServiceConfiguration, _ expected: KeycloakConfiguration) -> Bool {
        let issuer = expected.issuer
        return stored.issuer == issuer
            && stored.tokenEndpoint == issuer.appendingPathComponent("protocol/openid-connect/token")
            && ["auth", "registrations"].contains { endpoint in
                stored.authorizationEndpoint == issuer.appendingPathComponent("protocol/openid-connect/\(endpoint)")
            }
    }
}
