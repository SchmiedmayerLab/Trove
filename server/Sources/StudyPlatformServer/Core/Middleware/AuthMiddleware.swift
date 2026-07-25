//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import JWTKit
import Logging
import OpenAPIRuntime


struct AuthMiddleware: ServerMiddleware {
    let keyCollection: JWTKeyCollection
    let researcherRole: String
    let participantRole: String
    let logger: Logger

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        metadata: ServerRequestMetadata,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard let authHeader = request.headerFields[.authorization] else {
            throw ServerError.missingToken
        }

        guard authHeader.lowercased().hasPrefix("bearer "),
              authHeader.count > 7 else {
            throw ServerError.invalidToken
        }

        let token = String(authHeader.dropFirst(7))

        let payload: KeycloakJWTPayload
        do {
            payload = try await keyCollection.verify(token, as: KeycloakJWTPayload.self)
        } catch {
            logger.info("JWT verification failed: \(error)")
            throw ServerError.invalidToken
        }

        let authContext = AuthContext(
            subject: payload.sub.value,
            email: payload.email,
            roles: payload.roles,
            groups: payload.groups ?? [],
            researcherRole: researcherRole,
            participantRole: participantRole
        )

        return try await AuthContext.$current.withValue(authContext) {
            try await next(request, body, metadata)
        }
    }
}
