//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Grove
import GroveVapor
import JWTKit
import OpenAPIRuntime
import OpenAPIVapor
import TroveAPIServer
import Vapor


private var isServing: Bool {
    !CommandLine.arguments.dropFirst().contains(where: { $0 == "migrate" || $0 == "revert" })
}

private func usesEphemeralUITestServices(_ app: Application) -> Bool {
    app.environment == .testing && Environment.get("TROVE_UI_TEST_MODE") == "true"
}

private func configureDatabases(for app: Application, ephemeral: Bool) async throws {
    if ephemeral {
        app.logger.info("Configuring ephemeral UI-test databases...")
        try DatabaseConfiguration.inMemory.configure(for: app)
    } else {
        app.logger.info("Configuring PostgreSQL database connection...")
        try DatabaseConfiguration.postgres.configure(for: app)
    }
    configureMigrations(for: app)
    if ephemeral {
        try await app.autoMigrate()
        app.logger.info("Ephemeral UI-test databases configured.")
    } else {
        app.logger.info("PostgreSQL database configured.")
    }
}

private func configureDevelopmentCORS(for app: Application) {
    guard Environment.appEnvironment == .development else {
        return
    }
    app.middleware.use(
        CORSMiddleware(configuration: .init(
            allowedOrigin: .any(["http://localhost:3000", "http://localhost:3001"]),
            allowedMethods: [.GET, .POST, .PUT, .PATCH, .DELETE, .OPTIONS],
            allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith]
        )),
        at: .beginning
    )
}

private func configureObjectStorage(for app: Application, ephemeral: Bool) async throws {
    if ephemeral {
        app.logger.info("Configuring ephemeral UI-test object storage...")
        await configureServices(for: app, storageProvider: InMemoryObjectStorageProvider())
        return
    }

    app.logger.info("Connecting to S3 object storage...")
    let storageProvider = S3ObjectStorageProvider(config: S3ObjectStorageConfiguration())
    await configureServices(for: app, storageProvider: storageProvider)
    let storageService = app.grove[ObjectStorageService.self]
    try await storageService.ensureBucketExists()
    app.lifecycle.use(ObjectStorageLifecycle(storageService: storageService))
    app.logger.info("Object storage ready.")
}

/// Configures the application: database, migrations, and (when serving) services and routes.
public func configure(_ app: Application) async throws {
    let logger = app.logger
    let usesEphemeralServices = usesEphemeralUITestServices(app)
    logger.info("Starting server configuration (\(Environment.appEnvironment))...")

    try await configureDatabases(for: app, ephemeral: usesEphemeralServices)

    guard isServing else {
        return
    }

    configureDevelopmentCORS(for: app)
    try await configureObjectStorage(for: app, ephemeral: usesEphemeralServices)

    logger.info("Fetching groups from Keycloak")
    let keycloakConfig = KeycloakConfiguration()
    let keycloak = KeycloakClient(client: app.client, config: keycloakConfig)
    let groups = try await keycloak.fetchGroups()
    let groupService = app.grove[GroupService.self]
    try await groupService.syncGroups(from: groups)
    logger.info("Synced Keycloak groups to database.")

    logger.info("Fetching JWKS from Keycloak...")
    let jwks = try await keycloak.fetchJWKS()
    let keyCollection = JWTKeyCollection()
    try await keyCollection.add(jwks: jwks)
    logger.info("Loaded JWKS into key collection.")

    try configureRoutes(for: app, middlewares: [
        ErrorMiddleware(logger: app.logger),
        AuthMiddleware(
            keyCollection: keyCollection,
            researcherRole: keycloakConfig.researcherRole,
            participantRole: keycloakConfig.participantRole,
            logger: app.logger
        )
    ])
    logger.info("Server configuration complete.")
}

/// Configures services and repositories.
func configureServices(for app: Application, storageProvider: any ObjectStorageProvider) async {
    await app.grove.configure {
        ObjectStorageService(provider: storageProvider)

        AuthorizationService()
        GroupService()
        StudyService()
        ComponentService()
        ComponentScheduleService()
        StudyBundleService()
        InvitationCodeService()
        ProfileService()
        PublishedStudyService()
        EnrollmentService()
        ParticipantEnrollmentService()
        ConsentService()
        FHIRResourceService()

        GroupRepository(database: app.db(.psql))
        StudyRepository(database: app.db(.psql))
        ComponentRepository(database: app.db(.psql))
        ComponentScheduleRepository(database: app.db(.psql))
        InvitationCodeRepository(database: app.db(.psql))
        ProfileRepository(database: app.db(.psql))
        PublishedStudyRepository(database: app.db(.psql))
        EnrollmentRepository(database: app.db(.psql))
        ConsentRepository(database: app.db(.psql))
        FHIRResourceRepository(database: app.db(.timescale))
    }
}

/// The base path prefix for all API routes, derived from the OpenAPI spec.
public let apiBasePath = try! String(Servers.Server1.url().path.dropFirst()) // swiftlint:disable:this force_try

/// Registers OpenAPI routes and the health endpoint.
public func configureRoutes(for app: Application, middlewares: [any ServerMiddleware]) throws {
    let controller = Controller(grove: app.grove)

    let transport = VaporTransport(routesBuilder: app)
    try controller.registerHandlers(
        on: transport,
        serverURL: try Servers.Server1.url(),
        middlewares: middlewares
    )

    let components = apiBasePath.split(separator: "/")
    app.get(components.map { PathComponent(stringLiteral: String($0)) } + ["health"]) { _ async in
        ["status": "ok"]
    }
}


struct ObjectStorageLifecycle: Vapor.LifecycleHandler {
    let storageService: ObjectStorageService

    func shutdown(_ app: Application) {
        Task {
            try? await storageService.shutdown()
        }
    }
}
