//
// This source file is part of the StudyPlatform-iOS open source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
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

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "You are not signed in."
        case .couldNotStartSession: "Could not start authentication session."
        case .invalidCallback: "Authentication callback was invalid."
        case .tokenRefreshFailed: "Token refresh failed."
        case .missingIDToken: "Identity token missing from token response."
        case .deletionUnsupported: "Account deletion is not supported."
        }
    }
}
