//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Errors thrown by ``TroveAccountStorage``.
public enum TroveAccountError: LocalizedError {
    /// No signed-in user when an account-bound operation was attempted.
    case notSignedIn
    /// The REST client has not finished configuring.
    case clientUnavailable
    /// Server returned an unexpected response while loading the participant profile.
    case profileFetchFailed(underlying: Error)
    /// Server returned an unexpected response while persisting the participant profile.
    case profileUpdateFailed(underlying: Error)
    /// Account deletion is not supported by this provider.
    case deletionUnsupported

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "You are not signed in."
        case .clientUnavailable: "Trove API client is not ready."
        case .profileFetchFailed: "Could not load your profile."
        case .profileUpdateFailed: "Could not save your profile."
        case .deletionUnsupported: "Account deletion is not supported."
        }
    }
}
