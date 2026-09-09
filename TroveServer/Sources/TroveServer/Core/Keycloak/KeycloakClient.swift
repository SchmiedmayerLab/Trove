//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import JWTKit
import Vapor


struct KeycloakGroup: Decodable, Sendable {
    let id: UUID
    let name: String
    let subGroups: [KeycloakGroup]
}

enum KeycloakError: Error, CustomStringConvertible {
    case failedToAuthenticate(statusCode: Int)
    case failedToFetchGroups(statusCode: Int)

    var description: String {
        switch self {
        case let .failedToAuthenticate(statusCode):
            "Failed to authenticate with Keycloak (HTTP \(statusCode))"
        case let .failedToFetchGroups(statusCode):
            "Failed to fetch groups from Keycloak (HTTP \(statusCode))"
        }
    }
}

struct KeycloakClient: Sendable {
    private struct TokenResponse: Decodable {
        let access_token: String // swiftlint:disable:this identifier_name
    }

    let client: any Client
    let config: KeycloakConfiguration
    private let jwksBody: @Sendable () async throws -> ByteBuffer

    init(application: Application, config: KeycloakConfiguration) throws {
        let transport = try application.outboundTransport
        try transport.validateEndpoint(config.url)
        try transport.validateEndpoint(config.issuer)
        let httpClient = application.http.client.shared
        self.client = application.client
        self.config = config
        self.jwksBody = {
            let response = try await httpClient.execute(.init(url: config.jwksURL), timeout: .seconds(5))
            guard response.status == .ok else {
                throw KeycloakSigningKeys.RefreshError.unavailable
            }
            return try await response.body.collect(upTo: 65_536)
        }
    }

    func fetchGroups() async throws -> [KeycloakGroup] {
        let token = try await fetchAccessToken()

        let response = try await client.get(URI(string: "\(config.url)/admin/realms/\(config.realm)/groups")) { req in
            req.headers.bearerAuthorization = .init(token: token)
        }

        guard response.status == .ok else {
            throw KeycloakError.failedToFetchGroups(statusCode: Int(response.status.code))
        }

        return try response.content.decode([KeycloakGroup].self)
    }

    func fetchJWKS() async throws -> JWKS {
        let body = try await jwksBody()
        return try JSONDecoder().decode(JWKS.self, from: Data(body.readableBytesView))
    }

    private func fetchAccessToken() async throws -> String {
        let response = try await client.post(URI(string: "\(config.url)/realms/\(config.realm)/protocol/openid-connect/token")) { req in
            req.headers.contentType = .urlEncodedForm
            try req.content.encode([
                "grant_type": "client_credentials",
                "client_id": config.clientId,
                "client_secret": config.clientSecret
            ], as: .urlEncodedForm)
        }

        guard response.status == .ok else {
            throw KeycloakError.failedToAuthenticate(statusCode: Int(response.status.code))
        }

        let tokenResponse = try response.content.decode(TokenResponse.self)
        return tokenResponse.access_token
    }
}
