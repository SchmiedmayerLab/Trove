//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import NIOCore
import Synchronization
import Testing
@testable import TroveServer
import Vapor


struct KeycloakTransportTests {
    private static func chunkedJWKS(byteCount: Int) -> Response {
        Response(status: .ok, body: .init(managedAsyncStream: { writer in
            let document = "{\"keys\":[]}"
            try await writer.write(.buffer(.init(string: document)))
            var remaining = byteCount - document.utf8.count
            while remaining > 0 {
                let count = min(8_192, remaining)
                try await writer.write(.buffer(.init(string: String(repeating: " ", count: count))))
                remaining -= count
            }
        }))
    }

    @Test
    func signingKeysNeverFollowHTTPRedirects() async throws {
        let redirectWasServed = Mutex(false)
        try await withServer(configure: { app in
            app.get("realms", "fixture", "protocol", "openid-connect", "certs") { request in
                redirectWasServed.withLock { $0 = true }
                return request.redirect(to: "/redirect-target", redirectType: .temporary)
            }
            app.get("redirect-target") { _ in
                Issue.record("Signing-key transport followed a redirect outside the configured endpoint")
                return "{\"keys\":[]}"
            }
        }) { client in
            await #expect(throws: KeycloakSigningKeys.RefreshError.unavailable) {
                try await client.fetchJWKS()
            }
            #expect(redirectWasServed.withLock { $0 })
        }
    }

    @Test
    func oversizedChunkedSigningKeysAreRejectedBeforeDecoding() async throws {
        try await withServer(configure: { app in
            app.get("realms", "fixture", "protocol", "openid-connect", "certs") { _ in
                Self.chunkedJWKS(byteCount: 65_537)
            }
        }) { client in
            await #expect(throws: NIOTooManyBytesError.self) {
                try await client.fetchJWKS()
            }
        }
    }

    @Test
    func signingKeyBodyAtLimitIsAccepted() async throws {
        try await withServer(configure: { app in
            app.get("realms", "fixture", "protocol", "openid-connect", "certs") { _ in
                Self.chunkedJWKS(byteCount: 65_536)
            }
        }) { client in
            let jwks = try await client.fetchJWKS()
            #expect(jwks.keys.isEmpty)
        }
    }

    @Test
    func authorityTokenRequestsNeverFollowRedirects() async throws {
        try await withServer(configure: { app in
            app.post("realms", "fixture", "protocol", "openid-connect", "token") { request in
                request.redirect(to: "/credential-target", redirectType: .temporary)
            }
            app.post("credential-target") { _ in
                Issue.record("Authority transport forwarded credentials through a redirect")
                return "{}"
            }
        }) { client in
            await #expect(throws: KeycloakError.self) {
                try await client.fetchAuthority(for: .init(issuer: TestApp.issuer, subject: "grantor"))
            }
        }
    }

    @Test
    func oversizedAuthorityTokenResponseIsRejectedBeforeDecoding() async throws {
        try await withServer(configure: { app in
            app.post("realms", "fixture", "protocol", "openid-connect", "token") { _ in
                Self.chunkedJWKS(byteCount: 262_145)
            }
        }) { client in
            await #expect(throws: NIOTooManyBytesError.self) {
                try await client.fetchAuthority(for: .init(issuer: TestApp.issuer, subject: "grantor"))
            }
        }
    }

    @Test(arguments: [true, false])
    func authorityPaginationRequiresACompleteResult(terminates: Bool) async throws {
        try await withServer(configure: { app in
            app.post("realms", "fixture", "protocol", "openid-connect", "token") { _ in
                Response(status: .ok, body: .init(string: "{\"access_token\":\"synthetic-token\"}"))
            }
            app.get("admin", "realms", "fixture", "users", "grantor") { _ in
                Response(status: .ok, body: .init(string: "{\"id\":\"grantor\",\"enabled\":true}"))
            }
            app.get("admin", "realms", "fixture", "users", "grantor", "role-mappings", "realm", "composite") { _ in
                Response(status: .ok, body: .init(string: "[{\"name\":\"trove-researcher\"}]"))
            }
            app.get("admin", "realms", "fixture", "users", "grantor", "groups") { request in
                let first = try request.query.get(Int.self, at: "first")
                let paths = terminates && first == 100 ? ["/Test Group/admin"] : (0..<100).map { "/Group\(first + $0)/researcher" }
                let body = try JSONEncoder().encode(paths.map { ["path": $0] })
                return Response(status: .ok, body: .init(data: body))
            }
        }) { client in
            if terminates {
                let authority = try await client.fetchAuthority(for: .init(issuer: TestApp.issuer, subject: "grantor"))
                #expect(authority.groups.count == 101)
                #expect(authority.groups.last == "/Test Group/admin")
            } else {
                await #expect(throws: ServerError.self) {
                    try await client.fetchAuthority(for: .init(issuer: TestApp.issuer, subject: "grantor"))
                }
            }
        }
    }

    @Test(arguments: [
        (true, "Failed to authenticate with Keycloak (HTTP 401)"),
        (false, "Failed to fetch groups from Keycloak (HTTP 503)")
    ])
    func identityErrorResponsesDoNotExposeBodies(tokenFails: Bool, expectedDescription: String) async throws {
        let secretMarker = "synthetic-sensitive-identity-diagnostic"
        try await withServer(configure: { app in
            app.post("realms", "fixture", "protocol", "openid-connect", "token") { _ in
                if tokenFails {
                    return Response(status: .unauthorized, body: .init(string: secretMarker))
                }
                return Response(
                    status: .ok,
                    headers: ["Content-Type": "application/json"],
                    body: .init(string: "{\"access_token\":\"synthetic-access-token\"}")
                )
            }
            app.get("admin", "realms", "fixture", "groups") { _ in
                Response(status: .serviceUnavailable, body: .init(string: secretMarker))
            }
        }) { client in
            do {
                _ = try await client.fetchGroups()
                Issue.record("Failed identity request unexpectedly succeeded")
            } catch let error as KeycloakError {
                #expect(error.description == expectedDescription)
                #expect(!String(reflecting: error).contains(secretMarker))
            }
        }
    }

    private func withServer(
        configure: @Sendable (Application) -> Void,
        test: @Sendable (KeycloakClient) async throws -> Void
    ) async throws {
        let app = try await TestApp.makeApplication()
        // Resolving app.server captures the responder; register routes first.
        configure(app)
        let server = app.server
        do {
            try await server.start(address: .hostname("127.0.0.1", port: 0))
            let port = try #require(app.http.server.shared.localAddress?.port)
            let config = KeycloakConfiguration(
                issuer: TestApp.issuer,
                apiAudience: TestApp.apiAudience,
                url: "http://127.0.0.1:\(port)",
                realm: "fixture",
                clientId: "fixture-server",
                clientSecret: "synthetic-client-secret",
                researcherRole: TestApp.researcherRole,
                participantRole: TestApp.participantRole
            )
            try await test(KeycloakClient(application: app, config: config))
            await server.shutdown()
            try await app.asyncShutdown()
        } catch {
            await server.shutdown()
            try? await app.asyncShutdown()
            throw error
        }
    }
}
