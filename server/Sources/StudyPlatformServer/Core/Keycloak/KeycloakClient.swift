//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
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
    case failedToAuthenticate(statusCode: Int, body: String)
    case failedToFetchGroups(statusCode: Int, body: String)

    var description: String {
        switch self {
        case let .failedToAuthenticate(statusCode, body):
            "Failed to authenticate with Keycloak (HTTP \(statusCode)): \(body)"
        case let .failedToFetchGroups(statusCode, body):
            "Failed to fetch groups from Keycloak (HTTP \(statusCode)): \(body)"
        }
    }
}

struct KeycloakClient {
    private struct TokenResponse: Decodable {
        let access_token: String // swiftlint:disable:this identifier_name
    }

    let client: any Client
    let config: KeycloakConfiguration

    init(client: any Client, config: KeycloakConfiguration) {
        self.client = client
        self.config = config
    }

    func fetchGroups() async throws -> [KeycloakGroup] {
        let token = try await fetchAccessToken()

        let response = try await client.get(URI(string: "\(config.url)/admin/realms/\(config.realm)/groups")) { req in
            req.headers.bearerAuthorization = .init(token: token)
        }

        guard response.status == .ok else {
            let body = response.body.map { String(buffer: $0) } ?? ""
            throw KeycloakError.failedToFetchGroups(statusCode: Int(response.status.code), body: body)
        }

        return try response.content.decode([KeycloakGroup].self)
    }

    func fetchJWKS() async throws -> JWKS {
        let response = try await client.get(URI(string: config.jwksURL))

        guard response.status == .ok else {
            let body = response.body.map { String(buffer: $0) } ?? ""
            throw KeycloakError.failedToAuthenticate(statusCode: Int(response.status.code), body: body)
        }

        return try response.content.decode(JWKS.self)
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
            let body = response.body.map { String(buffer: $0) } ?? ""
            throw KeycloakError.failedToAuthenticate(statusCode: Int(response.status.code), body: body)
        }

        let tokenResponse = try response.content.decode(TokenResponse.self)
        return tokenResponse.access_token
    }
}
