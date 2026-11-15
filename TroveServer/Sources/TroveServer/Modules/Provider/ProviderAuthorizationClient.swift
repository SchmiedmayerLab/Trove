//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// OAuth transports have no database authority and cannot mint source identities.
protocol ProviderAuthorizationClient: Sendable {
    func exchange(
        registration: ProviderRegistration, code: String, redirect: URL, verifier: String?
    ) async throws -> ProviderCredentials

    func refresh(registration: ProviderRegistration, credentials: ProviderCredentials) async throws -> ProviderCredentials
}
