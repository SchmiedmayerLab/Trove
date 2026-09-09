//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import JWTKit
import NIOPosix
import OpenAPIRuntime
@testable import TroveServer
import Vapor
import VaporTesting


enum TestApp {
    enum Token: Sendable {
        /// No token — unauthenticated request.
        case none
        /// Researcher token with the given Keycloak group paths.
        case researcher(groups: [String] = ["/Test Group/admin"])
        /// Participant token with the given subject (identity provider ID).
        case participant(subject: String, email: String = "test@example.com")
    }

    // Synthetic fixtures only. At least 64 bytes also supports the HS512 rejection test.
    static let testSecret = String(repeating: "primary-test-key-", count: 4)
    static let rotatedTestSecret = String(repeating: "rotated-test-key-", count: 4)
    static let wrongTestSecret = String(repeating: "invalid-test-key-", count: 4)
    static let issuer = "https://identity.example.test/realms/trove"
    static let apiAudience = "trove-api"
    static let researcherRole = "trove-researcher"
    static let participantRole = "trove-participant"

    static func withApp(
        token tokenConfig: Token = .researcher(),
        storageProvider: any ObjectStorageProvider = InMemoryObjectStorageProvider(),
        validator: FHIRValidationClient? = nil,
        _ test: @escaping @Sendable (Application, String?) async throws -> Void
    ) async throws {
        let app = try await makeApplication()

        do {
            let keys = try await configureTesting(app, storageProvider: storageProvider, validator: validator)
            let token: String? = switch tokenConfig {
            case .none:
                nil
            case .researcher(let groups):
                try await signToken(keys: keys, subject: "researcher-test-user", roles: [researcherRole], groups: groups)
            case let .participant(subject, email):
                try await signToken(keys: keys, subject: subject, email: email, roles: [participantRole], groups: [])
            }
            try await test(app, token)
        } catch {
            do {
                try await TestDatabase.shutdown(app)
            } catch {
                app.logger.error("Isolated test database cleanup failed; disposable test databases may remain")
            }
            throw error
        }
        // Each invocation owns its complete database. Dispose it rather than
        // deleting domain rows through production relationships or audit guards.
        try await TestDatabase.shutdown(app)
    }

    /// Each application uses one existing loop so database pools do not grow with host CPU count.
    /// The shared NIO group owns the loop; application shutdown must not stop it.
    static func makeApplication() async throws -> Application {
        let app = try await Application.make(.testing, .shared(MultiThreadedEventLoopGroup.singleton.next()))
        try OutboundTransportConfiguration(environment: .development).configure(app)
        return app
    }

    static func withS3Storage(
        configuration: S3ObjectStorageConfiguration,
        test: @Sendable (S3ObjectStorageProvider) async throws -> Void
    ) async throws {
        let app = try await makeApplication()
        var provider: S3ObjectStorageProvider?
        do {
            let storage = try S3ObjectStorageProvider(application: app, config: configuration)
            provider = storage
            try await test(storage)
            try await storage.shutdown()
            provider = nil
            try await app.asyncShutdown()
        } catch {
            try? await provider?.shutdown()
            try? await app.asyncShutdown()
            throw error
        }
    }

    static func configureTesting(
        _ app: Application,
        storageProvider: any ObjectStorageProvider = InMemoryObjectStorageProvider(),
        validator: FHIRValidationClient? = nil
    ) async throws -> JWTKeyCollection {
        try await TestDatabase.configure(for: app)
        configureMigrations(for: app)
        try await app.autoMigrate()
        try await configureServices(for: app, storageProvider: storageProvider, validator: validator ?? FHIRValidationClient(application: app))

        return try await configureTransport(for: app)
    }

    static func configureTransport(for app: Application) async throws -> JWTKeyCollection {
        let keys = JWTKeyCollection()
        await keys.add(hmac: HMACKey(from: testSecret), digestAlgorithm: .sha256, kid: "test-key")
        await keys.add(hmac: HMACKey(from: rotatedTestSecret), digestAlgorithm: .sha256, kid: "rotated-test-key")

        let middlewares: [any ServerMiddleware] = [
            ErrorMiddleware(logger: app.logger),
            AuthMiddleware(
                keyProvider: FixedTokenKeys(collection: keys, identifiers: ["test-key", "rotated-test-key"]),
                tokenPolicy: try KeycloakTokenPolicy(issuer: issuer, apiAudience: apiAudience, algorithm: "HS256"),
                researcherRole: researcherRole,
                participantRole: participantRole,
                logger: app.logger,
                auditConfiguration: try .init(applicationRevision: "test-revision")
            )
        ]

        try configureRoutes(for: app, middlewares: middlewares)

        return keys
    }

    static func signToken(
        keys: JWTKeyCollection,
        subject: String = "test-user",
        email: String = "test@example.com", // swiftlint:disable:this function_default_parameter_at_end
        roles: [String],
        groups: [String],
        expiration: Date = Date().addingTimeInterval(3600)
    ) async throws -> String {
        let payload = KeycloakJWTPayload(
            iss: .init(value: issuer),
            aud: .init(value: [apiAudience]),
            sub: .init(value: subject),
            exp: .init(value: expiration),
            nbf: nil,
            email: email,
            roles: roles,
            groups: groups
        )
        return try await keys.sign(payload, kid: "test-key")
    }
}
