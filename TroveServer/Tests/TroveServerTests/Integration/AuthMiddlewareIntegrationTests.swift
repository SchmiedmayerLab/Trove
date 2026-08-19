//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Testing
@testable import TroveServer
import VaporTesting


@Suite(.serialized)
struct AuthMiddlewareIntegrationTests {
    @Test
    func malformedAuthorizationHeadersReturn401() async throws {
        try await TestApp.withApp(token: .none) { app, _ in
            for value in ["Basic credentials", "Bearer", "Bearer ", "Bearer malformed-token"] {
                try await app.test(.GET, "\(apiBasePath)/groups", beforeRequest: { request in
                    request.headers.replaceOrAdd(name: .authorization, value: value)
                }) { response in
                    #expect(response.status == .unauthorized)
                }
            }
        }
    }
}
