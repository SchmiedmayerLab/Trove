//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import JWTKit
import Logging
import OpenAPIRuntime


struct AuthMiddleware: ServerMiddleware {
    let keyProvider: any TokenKeyProvider
    let tokenPolicy: KeycloakTokenPolicy
    let researcherRole: String
    let participantRole: String
    let logger: Logger
    let auditConfiguration: AuditConfiguration

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
            // Unverified data is used only to restrict algorithms, never to authorize a request.
            let header = try DefaultJWTParser().parse(Array(token.utf8), as: KeycloakJWTPayload.self).header
            guard header.alg == tokenPolicy.algorithm,
                  let keyIdentifier = header.kid else {
                throw ServerError.invalidToken
            }
            let keyCollection = try await keyProvider.keys(for: keyIdentifier)
            let key = try await keyCollection.getKey(for: JWKIdentifier(string: keyIdentifier), alg: header.alg)
            guard key.name == tokenPolicy.algorithm else {
                throw ServerError.invalidToken
            }
            payload = try await keyCollection.verify(token, as: KeycloakJWTPayload.self)
            try tokenPolicy.verify(payload)
            try Task.checkCancellation()
        } catch KeycloakSigningKeys.RefreshError.unavailable {
            logger.error("Signing-key verification temporarily unavailable")
            throw ServerError(status: .serviceUnavailable, title: "Authentication Unavailable", detail: "Try again later")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Verification errors can contain claims. Never include them or the bearer token in diagnostics.
            logger.info("JWT verification failed")
            throw ServerError.invalidToken
        }

        let authContext = AuthContext(
            issuer: payload.iss.value,
            subject: payload.sub.value,
            email: payload.email,
            roles: payload.roles,
            groups: payload.groups ?? [],
            researcherRole: researcherRole,
            participantRole: participantRole,
            auditConfiguration: auditConfiguration
        )

        return try await AuthContext.$current.withValue(authContext) {
            try await next(request, body, metadata)
        }
    }
}
