//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import JWTKit
import OpenAPIRuntime
import OpenAPIVapor
import Spezi
import SpeziVapor
import StudyPlatformAPIServer
import Vapor


private var isServing: Bool {
    !CommandLine.arguments.dropFirst().contains(where: { $0 == "migrate" || $0 == "revert" })
}

/// Configures the application: database, migrations, and (when serving) services and routes.
public func configure(_ app: Application) async throws {
    let logger = app.logger
    logger.info("Starting server configuration (\(Environment.appEnvironment))...")

    logger.info("Configuring PostgreSQL database connection...")
    try DatabaseConfiguration.postgres.configure(for: app)
    configureMigrations(for: app)
    logger.info("PostgreSQL database configured.")


    guard isServing else {
        return
    }

    if Environment.appEnvironment == .development {
        app.middleware.use(
            CORSMiddleware(configuration: .init(
                allowedOrigin: .any(["http://localhost:3000"]),
                allowedMethods: [.GET, .POST, .PUT, .PATCH, .DELETE, .OPTIONS],
                allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith]
            )),
            at: .beginning
        )
    }

    logger.info("Connecting to S3 object storage...")
    let storageConfig = S3ObjectStorageConfiguration()
    let storageProvider = S3ObjectStorageProvider(config: storageConfig)
    await configureServices(for: app, storageProvider: storageProvider)
    let storageService = app.spezi[ObjectStorageService.self]
    try await storageService.ensureBucketExists()
    app.lifecycle.use(ObjectStorageLifecycle(storageService: storageService))
    logger.info("Object storage ready.")

    logger.info("Fetching groups from Keycloak")
    let keycloakConfig = KeycloakConfiguration()
    let keycloak = KeycloakClient(client: app.client, config: keycloakConfig)
    let groups = try await keycloak.fetchGroups()
    let groupService = app.spezi[GroupService.self]
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
    await app.spezi.configure {
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
    let controller = Controller(spezi: app.spezi)

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
