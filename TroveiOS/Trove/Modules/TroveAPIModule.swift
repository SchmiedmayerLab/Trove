//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Grove
import OpenAPIURLSession
import TroveAPIClient


final class TroveAPIModule: Module, EnvironmentAccessible {
    @Dependency(KeycloakAccountService.self) private var keycloak

    private(set) var client: Client?

    init() {}

    func configure() {
        client = Client(
            serverURL: Config.apiBaseURL,
            transport: URLSessionTransport(),
            middlewares: [
                BearerAuthMiddleware { [weak self] in
                    guard let self else {
                        return nil
                    }
                    return try await self.keycloak.currentAccessToken()
                }
            ]
        )
    }

    /// The configured REST client, or ``TroveAccountError/clientUnavailable`` before ``configure()`` has run.
    func requireClient() throws -> Client {
        guard let client else {
            throw TroveAccountError.clientUnavailable
        }
        return client
    }
}
