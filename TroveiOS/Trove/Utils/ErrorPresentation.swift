//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import OpenAPIRuntime


/// Only reviewed app messages cross the boundary from transport errors into presentation.
enum ErrorPresentation: Equatable, Sendable {
    case unexpectedFailure
    case notSignedIn
    case authenticationFailed
    case clientUnavailable
    case profileFetchFailed
    case profileUpdateFailed
    case deletionUnsupported
    case enrollmentUnavailable
    case enrollmentMutationInProgress
    case networkUnavailable

    var message: LocalizedStringResource {
        switch self {
        case .unexpectedFailure: "Something went wrong. Please try again."
        case .notSignedIn: "You are not signed in."
        case .authenticationFailed: "Could not authenticate. Please sign in again."
        case .clientUnavailable: "Trove API client is not ready."
        case .profileFetchFailed: "Could not load your profile."
        case .profileUpdateFailed: "Could not save your profile."
        case .deletionUnsupported: "Account deletion is not supported."
        case .enrollmentUnavailable: "Enrollment status must be loaded before it can be changed."
        case .enrollmentMutationInProgress: "Another enrollment change is already in progress."
        case .networkUnavailable: "Could not connect. Check your connection and try again."
        }
    }

    init?(_ error: any Error) {
        guard !Self.isCancellation(error) else {
            return nil
        }
        switch error {
        case let error as EnrollmentModelError:
            switch error {
            case .enrollmentStateUnavailable: self = .enrollmentUnavailable
            case .mutationInProgress: self = .enrollmentMutationInProgress
            }
        case let error as TroveAccountError:
            self = Self.account(error)
        case let error as KeycloakAccountError:
            self = Self.authentication(error)
        case is URLError:
            self = .networkUnavailable
        default:
            // LocalizedError is not a trust boundary: server descriptions and bodies can conform too.
            self = .unexpectedFailure
        }
    }

    private static func account(_ error: TroveAccountError) -> Self {
        switch error {
        case .notSignedIn: .notSignedIn
        case .clientUnavailable: .clientUnavailable
        case .profileFetchFailed: .profileFetchFailed
        case .profileUpdateFailed: .profileUpdateFailed
        case .deletionUnsupported: .deletionUnsupported
        }
    }

    private static func authentication(_ error: KeycloakAccountError) -> Self {
        switch error {
        case .notSignedIn: .notSignedIn
        case .deletionUnsupported: .deletionUnsupported
        case .couldNotStartSession, .invalidCallback, .tokenRefreshFailed, .missingIDToken, .authenticationFailed:
            .authenticationFailed
        }
    }

    /// Inspect only known structural wrappers, never their descriptions or payloads.
    static func isCancellation(_ error: any Error) -> Bool {
        var current = error
        for _ in 0..<8 {
            if current is CancellationError {
                return true
            }
            if let client = current as? ClientError {
                current = client.underlyingError
                continue
            }
            if let account = current as? TroveAccountError {
                switch account {
                case .profileFetchFailed(let underlying), .profileUpdateFailed(let underlying):
                    current = underlying
                default:
                    return false
                }
                continue
            }
            let native = current as NSError
            if native.domain == NSURLErrorDomain, native.code == NSURLErrorCancelled {
                return true
            }
            if let underlying = native.userInfo[NSUnderlyingErrorKey] as? any Error {
                current = underlying
            } else {
                return false
            }
        }
        return false
    }
}
