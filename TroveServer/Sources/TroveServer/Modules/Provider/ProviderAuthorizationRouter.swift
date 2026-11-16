//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Provider selection comes from the approved immutable registration, not an OAuth redirect.
struct ProviderAuthorizationRouter: ProviderAuthorizationClient {
    let transport: ProviderHTTPTransport
    let secrets: ProviderApplicationSecrets

    func exchange(registration: ProviderRegistration, code: String, redirect: URL, verifier: String?) async throws -> ProviderCredentials {
        try await client(for: registration.provider).exchange(registration: registration, code: code, redirect: redirect, verifier: verifier)
    }

    func refresh(registration: ProviderRegistration, credentials: ProviderCredentials) async throws -> ProviderCredentials {
        try await client(for: registration.provider).refresh(registration: registration, credentials: credentials)
    }

    private func client(for provider: ConnectedProvider) -> any ProviderAuthorizationClient {
        switch provider {
        case .withings: WithingsAuthorizationClient(transport: transport, secrets: secrets)
        case .oura: OuraAuthorizationClient(transport: transport, secrets: secrets)
        case .googleHealthAPI: GoogleHealthAuthorizationClient(transport: transport, secrets: secrets)
        }
    }
}
