//
// This source file is part of the StudyPlatform-iOS open source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import OpenAPIURLSession
import Spezi
import StudyPlatformAPIClient


final class StudyPlatformAPIModule: Module, EnvironmentAccessible {
    @Dependency(KeycloakAccountService.self) private var keycloak

    private(set) var client: Client!

    init() {}

    func configure() {
        client = Client(
            serverURL: Config.apiBaseURL,
            transport: URLSessionTransport(),
            middlewares: [BearerAuthMiddleware { [weak self] in
                guard let self else { return nil }
                return try await self.keycloak.currentAccessToken()
            }]
        )
    }
}
