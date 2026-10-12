//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import AsyncHTTPClient
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
    case failedToFetchAuthority(statusCode: Int)

    var description: String {
        switch self {
        case let .failedToAuthenticate(statusCode):
            "Failed to authenticate with Keycloak (HTTP \(statusCode))"
        case let .failedToFetchGroups(statusCode):
            "Failed to fetch groups from Keycloak (HTTP \(statusCode))"
        case let .failedToFetchAuthority(statusCode):
            "Failed to verify current Keycloak authority (HTTP \(statusCode))"
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
    private let authorityDocument: @Sendable (String, String?, Data?) async throws -> Data

    var authorityProvider: GrantorAuthorityProvider {
        .init { actor in
            do {
                return try await fetchAuthority(for: actor)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // No response body, identity details or credentials escape this boundary.
                throw ServerError(status: .serviceUnavailable, title: "Authorization Unavailable", detail: "Try again later")
            }
        }
    }

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
        self.authorityDocument = { url, bearer, form in
            var request = HTTPClientRequest(url: url)
            request.method = form == nil ? .GET : .POST
            if let bearer {
                request.headers.add(name: "Authorization", value: "Bearer \(bearer)")
            }
            if let form {
                request.headers.add(name: "Content-Type", value: "application/x-www-form-urlencoded")
                request.body = .bytes(form)
            }
            let response = try await httpClient.execute(request, timeout: .seconds(5))
            guard response.status == .ok else {
                throw KeycloakError.failedToFetchAuthority(statusCode: Int(response.status.code))
            }
            let body = try await response.body.collect(upTo: 262_144)
            return Data(body.readableBytesView)
        }
    }

    private static func encodeSegment(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
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

    /// Read-through authority for this operation, never claims cached from token issuance.
    func fetchAuthority(for actor: AuditActor) async throws -> GrantorAuthority {
        struct User: Decodable {
            let id: String
            let enabled: Bool
        }
        struct Role: Decodable {
            let name: String
        }
        struct Membership: Decodable {
            let path: String
        }
        guard actor.issuer == config.issuer, !actor.subject.isEmpty, actor.subject.utf8.count <= 255 else {
            throw ServerError.forbidden
        }
        let form = ["grant_type": "client_credentials", "client_id": config.clientId, "client_secret": config.clientSecret]
            .sorted(by: { $0.key < $1.key })
            .map { "\(Self.encodeSegment($0.key))=\(Self.encodeSegment($0.value))" }
            .joined(separator: "&")
        let tokenBody = try await authorityDocument(
            "\(config.url)/realms/\(Self.encodeSegment(config.realm))/protocol/openid-connect/token", nil, Data(form.utf8)
        )
        let token = try JSONDecoder().decode(TokenResponse.self, from: tokenBody).access_token
        let base = "\(config.url)/admin/realms/\(Self.encodeSegment(config.realm))/users/\(Self.encodeSegment(actor.subject))"
        let user = try JSONDecoder().decode(User.self, from: await authorityDocument(base, token, nil))
        guard user.id == actor.subject else { throw ServerError.forbidden }
        guard user.enabled else {
            return .init(issuer: actor.issuer, subject: actor.subject, enabled: false, roles: [], groups: [])
        }
        let roles = try JSONDecoder().decode([Role].self, from: await authorityDocument("\(base)/role-mappings/realm/composite", token, nil))
        var groups: [String] = []
        // An explicit bound prevents a malformed upstream from extending authorization indefinitely.
        // Exceeding it fails closed rather than using a truncated set of memberships.
        for page in 0..<10 {
            try Task.checkCancellation()
            let url = "\(base)/groups?first=\(page * 100)&max=100&briefRepresentation=true"
            let memberships = try JSONDecoder().decode([Membership].self, from: await authorityDocument(url, token, nil))
            guard memberships.count <= 100 else { throw ServerError.forbidden }
            groups.append(contentsOf: memberships.map(\.path))
            if memberships.count < 100 {
                return .init(issuer: actor.issuer, subject: actor.subject, enabled: true, roles: roles.map(\.name), groups: groups)
            }
        }
        throw ServerError(status: .serviceUnavailable, title: "Authorization Unavailable", detail: "Group membership response exceeded its limit")
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
