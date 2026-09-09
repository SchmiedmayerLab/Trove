//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import Trove


struct BearerAuthMiddlewareTests {
    private actor Session {
        var isValid = true
        var requests: [HTTPRequest] = []

        func invalidate() { isValid = false }

        func validate() throws {
            guard isValid else { throw CancellationError() }
        }

        func record(_ request: HTTPRequest) { requests.append(request) }
    }

    private static let endpoint = URL(string: "https://example.invalid")!
    private static let request = HTTPRequest(method: .get, scheme: "https", authority: "example.invalid", path: "/profile")

    @Test
    func attachesCapturedToken() async throws {
        let session = Session()
        let middleware = BearerAuthMiddleware(tokenProvider: { "session-a" }, validateSession: { try await session.validate() })
        let response = try await middleware.intercept(
            Self.request, body: nil, baseURL: Self.endpoint, operationID: "profile"
        ) { request, _, _ in
            await session.record(request)
            return (HTTPResponse(status: .ok), nil)
        }
        #expect(response.0.status == .ok)
        #expect(await session.requests.map { $0.headerFields[.authorization] } == ["Bearer session-a"])
    }

    @Test
    func invalidatedTokenRefreshDoesNotSend() async {
        let session = Session()
        let middleware = BearerAuthMiddleware(
            tokenProvider: {
                await session.invalidate()
                return "session-a"
            },
            validateSession: { try await session.validate() }
        )
        await #expect(throws: CancellationError.self) {
            _ = try await middleware.intercept(
                Self.request, body: nil, baseURL: Self.endpoint, operationID: "profile"
            ) { request, _, _ in
                await session.record(request)
                return (HTTPResponse(status: .ok), nil)
            }
        }
        #expect(await session.requests.isEmpty)
    }

    @Test
    func accountChangeDuringRequestDiscardsResponse() async {
        let session = Session()
        let middleware = BearerAuthMiddleware(tokenProvider: { "session-a" }, validateSession: { try await session.validate() })
        await #expect(throws: CancellationError.self) {
            _ = try await middleware.intercept(
                Self.request, body: nil, baseURL: Self.endpoint, operationID: "profile"
            ) { request, _, _ in
                await session.record(request)
                await session.invalidate()
                return (HTTPResponse(status: .ok), nil)
            }
        }
        #expect(await session.requests.count == 1)
    }

    @Test
    func emptyTokenNeverSendsAnonymousRequest() async {
        let session = Session()
        let middleware = BearerAuthMiddleware(tokenProvider: { "" }, validateSession: { try await session.validate() })
        await #expect(throws: KeycloakAccountError.self) {
            _ = try await middleware.intercept(
                Self.request, body: nil, baseURL: Self.endpoint, operationID: "profile"
            ) { request, _, _ in
                await session.record(request)
                return (HTTPResponse(status: .ok), nil)
            }
        }
        #expect(await session.requests.isEmpty)
    }
}
