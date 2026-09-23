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
        if !app.environment.isDatabaseMigration {
            try await DatabaseRuntimePrivileges.validate(on: app.db)
        }
        try await DatabaseConfiguration.postgres.validatePrerequisites(for: app, runtime: !app.environment.isDatabaseMigration)
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
            allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith, .ifMatch, "Trove-Delegation-ID"]
        )),
        at: .beginning
    )
}

private func configureObjectStorage(for app: Application, ephemeral: Bool, keycloak: KeycloakClient) async throws {
    if ephemeral {
        app.logger.info("Configuring ephemeral UI-test object storage...")
        try await configureServices(
            for: app,
            storageProvider: InMemoryObjectStorageProvider(),
            validator: FHIRValidationClient(application: app),
            grantorAuthority: keycloak.authorityProvider,
            clientPolicy: keycloak.config.clientPolicy
        )
        return
    }

    app.logger.info("Connecting to S3 object storage...")
    let validator = try FHIRValidationClient(application: app)
    let storageProvider = try S3ObjectStorageProvider(application: app, config: S3ObjectStorageConfiguration())
    await configureServices(
        for: app,
        storageProvider: storageProvider,
        validator: validator,
        grantorAuthority: keycloak.authorityProvider,
        clientPolicy: keycloak.config.clientPolicy
    )
    let storageService = app.grove[ObjectStorageService.self]
    app.lifecycle.use(ObjectStorageLifecycle(storageService: storageService))
    try await storageService.ensureBucketExists()
    app.logger.info("Object storage ready.")
}

/// Configures the application: database, migrations, and (when serving) services and routes.
public func configure(_ app: Application) async throws {
    let auditConfiguration = try AuditConfiguration(applicationRevision: Environment.get("APPLICATION_REVISION"))
    if app.environment.isServing {
        try InboundTransportConfiguration(
            environment: Environment.appEnvironment,
            certificateFile: Environment.get("TLS_CERTIFICATE_FILE"),
            privateKeyFile: Environment.get("TLS_PRIVATE_KEY_FILE")
        ).configure(app)
    }
    try OutboundTransportConfiguration(
        environment: Environment.appEnvironment,
        certificateAuthorityFile: Environment.get("TLS_CA_FILE")
    ).configure(app)
    app.asyncCommands.use(CleanupArtifactsCommand(auditConfiguration: auditConfiguration), as: "cleanup-artifacts")
    let logger = app.logger
    let usesEphemeralServices = usesEphemeralUITestServices(app)
    let keycloakConfig: KeycloakConfiguration? = app.environment.isServing ? .init() : nil
    // Validate the trusted token boundary before connecting services or accepting traffic.
    let tokenPolicy = try keycloakConfig?.tokenPolicy
    let keycloak = try keycloakConfig.map { try KeycloakClient(application: app, config: $0) }
    logger.info("Starting server configuration (\(Environment.appEnvironment))...")

    try await configureDatabases(for: app, ephemeral: usesEphemeralServices)
    // Accessing the database installs Fluent's default command first.
    app.asyncCommands.use(InitializeDatabaseCommand(), as: "migrate")

    guard app.environment.isServing else {
        return
    }
    guard let keycloakConfig, let tokenPolicy, let keycloak else {
        throw ServerError.internalServerError("Token verification is not configured")
    }

    configureDevelopmentCORS(for: app)
    try await configureObjectStorage(for: app, ephemeral: usesEphemeralServices, keycloak: keycloak)

    logger.info("Fetching groups from Keycloak")
    let groups = try await keycloak.fetchGroups()
    let groupService = app.grove[GroupService.self]
    try await groupService.syncGroups(from: groups)

    let jwks = try await keycloak.fetchJWKS()
    let signingKeys = try await KeycloakSigningKeys(initialJWKS: jwks) {
        try await keycloak.fetchJWKS()
    }

    try configureRoutes(for: app, middlewares: [
        ErrorMiddleware(logger: app.logger),
        AuthMiddleware(
            keyProvider: signingKeys,
            tokenPolicy: tokenPolicy,
            researcherRole: keycloakConfig.researcherRole,
            participantRole: keycloakConfig.participantRole,
            logger: app.logger,
            auditConfiguration: auditConfiguration,
            clientPolicy: keycloakConfig.clientPolicy
        )
    ])
    logger.info("Server configuration complete.")
}

/// Configures services and repositories.
func configureServices(
    for app: Application,
    storageProvider: any ObjectStorageProvider,
    validator: FHIRValidationClient,
    grantorAuthority: GrantorAuthorityProvider = .unavailable,
    clientPolicy: KeycloakClientPolicy = .production
) async {
    await app.grove.configure {
        ObjectStorageService(provider: storageProvider)

        AuthorizationService(grantorAuthority: grantorAuthority)
        DelegationService(clientPolicy: clientPolicy)
        GroupService()
        StudyService()
        ComponentService()
        ComponentScheduleService()
        StudyBundleService()
        StudyValidationService(validator: validator)
        InvitationCodeService()
        ProfileService()
        SourceBindingService(database: app.db(.psql))
        ClinicalEventService(database: app.db(.psql), validator: validator)
        PublishedStudyService()
        EnrollmentService()
        ParticipantEnrollmentService()
        ConsentService()

        GroupRepository(database: app.db(.psql))
        StudyRepository(database: app.db(.psql))
        ComponentRepository(database: app.db(.psql))
        ComponentScheduleRepository(database: app.db(.psql))
        InvitationCodeRepository(database: app.db(.psql))
        ProfileRepository(database: app.db(.psql))
        PublishedStudyRepository(database: app.db(.psql))
        EnrollmentRepository(database: app.db(.psql))
        ConsentRepository(database: app.db(.psql))
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
        configuration: .trove,
        middlewares: middlewares + [ClinicalRequestBodyMiddleware()]
    )

    let components = apiBasePath.split(separator: "/")
    app.get(components.map { PathComponent(stringLiteral: String($0)) } + ["health"]) { _ async in
        ["status": "ok"]
    }
}


struct ObjectStorageLifecycle: Vapor.LifecycleHandler {
    let storageService: ObjectStorageService

    func shutdownAsync(_ app: Application) async {
        do {
            try await storageService.shutdown()
        } catch {
            app.logger.error("Object storage shutdown failed")
        }
    }
}
