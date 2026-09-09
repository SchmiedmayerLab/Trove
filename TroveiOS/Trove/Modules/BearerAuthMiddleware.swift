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


struct BearerAuthMiddleware: ClientMiddleware {
    let tokenProvider: @Sendable () async throws -> String
    let validateSession: @Sendable () async throws -> Void

    init(
        tokenProvider: @escaping @Sendable () async throws -> String,
        validateSession: @escaping @Sendable () async throws -> Void
    ) {
        self.tokenProvider = tokenProvider
        self.validateSession = validateSession
    }

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable @concurrent (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var mutableRequest = request
        try Task.checkCancellation()
        let token = try await tokenProvider()
        guard !token.isEmpty else {
            throw KeycloakAccountError.notSignedIn
        }
        try await validateSession()
        try Task.checkCancellation()
        mutableRequest.headerFields[.authorization] = "Bearer \(token)"
        let response = try await next(mutableRequest, body, baseURL)
        try await validateSession()
        // A response already received can reconcile a mutation even if its view task ended.
        return response
    }
}
