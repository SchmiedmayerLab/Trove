//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Grove
import OpenAPIURLSession
import TroveAPIClient
import TroveHealthKit


@MainActor
final class TroveAPIModule: Module, EnvironmentAccessible {
    @Dependency(KeycloakAccountService.self) private var keycloak

    private var isConfigured = false

    var sessionSnapshot: KeycloakSessionSnapshot? {
        keycloak.sessionSnapshot
    }

    init() {}

    func configure() {
        isConfigured = true
    }

    func validateSession(_ snapshot: KeycloakSessionSnapshot) throws {
        try keycloak.validateSession(snapshot)
    }

    /// Every client is bound to the session that initiated its work, including delayed requests.
    func requireClient(for snapshot: KeycloakSessionSnapshot) throws -> Client {
        guard isConfigured else {
            throw TroveAccountError.clientUnavailable
        }
        try validateSession(snapshot)
        let service = keycloak
        return Client(
            serverURL: Config.apiBaseURL,
            configuration: .trove,
            transport: URLSessionTransport(),
            middlewares: [
                BearerAuthMiddleware(
                    tokenProvider: { try await service.token(for: snapshot) },
                    validateSession: { try await service.validateSession(snapshot) }
                )
            ]
        )
    }

    /// Captures the current session once; middleware must never select a newer account's token.
    func requireClient() throws -> Client {
        guard isConfigured else {
            throw TroveAccountError.clientUnavailable
        }
        guard let snapshot = sessionSnapshot else {
            throw TroveAccountError.notSignedIn
        }
        return try requireClient(for: snapshot)
    }

    /// Reuses the existing session-bound transport; constructing a drainer does not enable collection.
    func makeDeliveryDrainer(journal: EventDeliveryJournal, for snapshot: KeycloakSessionSnapshot) throws -> EventDeliveryDrainer {
        let client = try requireClient(for: snapshot)
        let service = keycloak
        return try EventDeliveryDrainer(
            journal: journal,
            scope: .init(backend: Config.apiBaseURL.absoluteString, issuer: snapshot.issuer.absoluteString, subject: snapshot.subject),
            client: client,
            validateSession: { try await service.validateSession(snapshot) }
        )
    }

    /// Restores an existing setup using exactly the initiating account; never creates a replacement stream.
    func synchronizeSource(
        localID: UUID, journal: EventDeliveryJournal, for snapshot: KeycloakSessionSnapshot
    ) async throws -> EventDeliveryJournal.SourceSetup {
        let client = try requireClient(for: snapshot)
        let service = keycloak
        return try await SourceRegistration.synchronize(
            journal: journal,
            scope: .init(backend: Config.apiBaseURL.absoluteString, issuer: snapshot.issuer.absoluteString, subject: snapshot.subject),
            localID: localID,
            client: client,
            validateSession: { try await service.validateSession(snapshot) }
        )
    }

    /// Supplies the existing captured-session client; does not start acquisition or request HealthKit access.
    func makeHeartRateAcquisition(journal: EventDeliveryJournal, for snapshot: KeycloakSessionSnapshot) throws -> HeartRateAcquisition {
        let client = try requireClient(for: snapshot)
        let service = keycloak
        return try HeartRateAcquisition(
            journal: journal,
            scope: .init(backend: Config.apiBaseURL.absoluteString, issuer: snapshot.issuer.absoluteString, subject: snapshot.subject),
            client: client,
            validateSession: { try await service.validateSession(snapshot) }
        )
    }
}
