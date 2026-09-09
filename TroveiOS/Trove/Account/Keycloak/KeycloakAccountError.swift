//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Errors thrown by ``KeycloakAccountService``.
public enum KeycloakAccountError: LocalizedError {
    /// The user is not currently signed in.
    case notSignedIn
    /// The OIDC code-grant flow could not be presented.
    case couldNotStartSession
    /// The OIDC callback returned no auth state.
    case invalidCallback
    /// Refreshing the access token failed.
    case tokenRefreshFailed
    /// The ID token was missing from the token response.
    case missingIDToken
    /// Account deletion is not supported by this provider.
    case deletionUnsupported
    /// Authentication failed without a safe provider-supplied message to display.
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: String(localized: "You are not signed in.")
        case .couldNotStartSession: String(localized: "Could not start authentication session.")
        case .invalidCallback: String(localized: "Authentication callback was invalid.")
        case .tokenRefreshFailed: String(localized: "Token refresh failed.")
        case .missingIDToken: String(localized: "Identity token missing from token response.")
        case .deletionUnsupported: String(localized: "Account deletion is not supported.")
        case .authenticationFailed: String(localized: "Could not sign in. Please try again.")
        }
    }
}
