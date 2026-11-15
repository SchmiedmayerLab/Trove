//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import Trove
import TroveAPIClient


@MainActor
struct ProviderConnectionsModelTests {
    private actor HTTP: ClientTransport {
        let intent: Components.Schemas.ProviderLinkIntent
        let connection: Components.Schemas.ProviderConnection
        let registrations: [Components.Schemas.ProviderRegistration]
        let connections: [Components.Schemas.ProviderConnection]
        let failingOperation: String?
        var operations: [String] = []

        init(
            intent: Components.Schemas.ProviderLinkIntent,
            connection: Components.Schemas.ProviderConnection,
            registrations: [Components.Schemas.ProviderRegistration] = [],
            connections: [Components.Schemas.ProviderConnection] = [],
            failingOperation: String? = nil
        ) {
            self.intent = intent
            self.connection = connection
            self.registrations = registrations
            self.connections = connections
            self.failingOperation = failingOperation
        }

        func send(
            _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
        ) async throws -> (HTTPResponse, HTTPBody?) {
            operations.append(operationID)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if operationID == failingOperation {
                return (.init(status: .serviceUnavailable), nil)
            }
            let bytes: Data
            switch operationID {
            case "getParticipantProviderRegistrations": bytes = try encoder.encode(registrations)
            case "getParticipantProviderConnections": bytes = try encoder.encode(connections)
            case "startParticipantProviderLink": bytes = try encoder.encode(intent)
            case "completeParticipantProviderLink": bytes = try encoder.encode(connection)
            default: throw ProviderConnectionsModel.Failure.unavailable
            }
            return (.init(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(bytes))
        }
    }

    private static let redirect = URL(string: "https://app.example.org/provider/callback")!
    private static let issuer = URL(string: "https://identity.example.org/realm")!
    private static let state = String(repeating: "a", count: 43)
    private static let registration = Components.Schemas.ProviderRegistration(
        id: "10000000-0000-4000-8000-000000000001",
        provider: .withings,
        displayName: "Wearable service",
        controller: "Study operator",
        region: "EU",
        redirects: [.init(id: "native", uri: redirect.absoluteString)],
        capabilities: []
    )

    @Test(arguments: [false, true])
    func completionRemainsBoundToTheAccountThatStartedAuthorization(switchAccount: Bool) async throws {
        let lifecycle = KeycloakSessionLifecycle()
        try lifecycle.install(subject: "first", issuer: Self.issuer, for: lifecycle.generation)
        let connection = Components.Schemas.ProviderConnection(
            id: UUID().uuidString,
            registrationId: Self.registration.id,
            sourceId: UUID().uuidString,
            state: .active,
            generation: 1,
            requiresReauthorization: false
        )
        let http = HTTP(intent: .init(
            id: UUID().uuidString,
            authorizationUrl: "https://provider.example.org/authorize",
            redirectUri: Self.redirect.absoluteString,
            expiresAt: .now.addingTimeInterval(600)
        ), connection: connection)
        let model = makeModel(lifecycle: lifecycle, http: http)
        let redirect = try #require(Self.registration.redirects.first)
        await model.connect(registration: Self.registration, redirect: redirect) { _, _ in
            if switchAccount {
                lifecycle.invalidate()
                try lifecycle.install(subject: "second", issuer: Self.issuer, for: lifecycle.generation)
            }
            return Self.redirect.appending(queryItems: [.init(name: "state", value: Self.state), .init(name: "code", value: "synthetic-code")])
        }
        let calls = await http.operations
        #expect(calls == (switchAccount ? ["startParticipantProviderLink"] : ["startParticipantProviderLink", "completeParticipantProviderLink"]))
        #expect(model.connections == (switchAccount ? [] : [connection]))
        #expect(!model.hasFailed && !model.isBusy)
    }

    @Test
    func cancelledBrowserNeverCompletesTheLinkIntent() async throws {
        let lifecycle = KeycloakSessionLifecycle()
        try lifecycle.install(subject: "first", issuer: Self.issuer, for: lifecycle.generation)
        let http = HTTP(intent: .init(
            id: UUID().uuidString,
            authorizationUrl: "https://provider.example.org/authorize",
            redirectUri: Self.redirect.absoluteString,
            expiresAt: .now.addingTimeInterval(600)
        ), connection: .init(
            id: UUID().uuidString,
            registrationId: Self.registration.id,
            sourceId: UUID().uuidString,
            state: .active,
            generation: 1,
            requiresReauthorization: false
        ))
        let model = makeModel(lifecycle: lifecycle, http: http)
        await model.connect(registration: Self.registration, redirect: try #require(Self.registration.redirects.first)) { _, _ in
            throw CancellationError()
        }
        #expect(await http.operations == ["startParticipantProviderLink"])
        #expect(model.connections.isEmpty && !model.hasFailed && !model.isBusy)
    }

    @Test
    func deploymentWithoutProviderIntegrationOffersNoWearableServicesWithoutFailure() async throws {
        let model = try await refreshedModel(registrations: [], connections: [])
        #expect(!model.offersWearableServices)
        #expect(!model.hasFailed && !model.isBusy)
        #expect(model.registrations.isEmpty && model.connections.isEmpty)
    }

    @Test
    func offeredRegistrationShowsWearableServices() async throws {
        let model = try await refreshedModel(registrations: [Self.registration], connections: [])
        #expect(model.offersWearableServices)
        #expect(!model.hasFailed)
        #expect(model.registrations == [Self.registration])
    }

    @Test(arguments: ["getParticipantProviderRegistrations", "getParticipantProviderConnections"])
    func failureInConfiguredDeploymentIsReported(failingOperation: String) async throws {
        let model = try await refreshedModel(registrations: [Self.registration], connections: [], failingOperation: failingOperation)
        #expect(model.hasFailed)
        #expect(model.offersWearableServices)
        #expect(!model.isBusy)
    }

    private func refreshedModel(
        registrations: [Components.Schemas.ProviderRegistration],
        connections: [Components.Schemas.ProviderConnection],
        failingOperation: String? = nil
    ) async throws -> ProviderConnectionsModel {
        let lifecycle = KeycloakSessionLifecycle()
        try lifecycle.install(subject: "first", issuer: Self.issuer, for: lifecycle.generation)
        let http = HTTP(
            intent: .init(
                id: UUID().uuidString,
                authorizationUrl: "https://provider.example.org/authorize",
                redirectUri: Self.redirect.absoluteString,
                expiresAt: .now.addingTimeInterval(600)
            ),
            connection: .init(
                id: UUID().uuidString,
                registrationId: Self.registration.id,
                sourceId: UUID().uuidString,
                state: .active,
                generation: 1,
                requiresReauthorization: false
            ),
            registrations: registrations,
            connections: connections,
            failingOperation: failingOperation
        )
        let model = makeModel(lifecycle: lifecycle, http: http)
        #expect(!model.offersWearableServices)
        await model.refresh()
        if failingOperation == nil {
            #expect(Set(await http.operations) == ["getParticipantProviderRegistrations", "getParticipantProviderConnections"])
        }
        return model
    }

    private func makeModel(lifecycle: KeycloakSessionLifecycle, http: HTTP) -> ProviderConnectionsModel {
        ProviderConnectionsModel(transport: .init(
            session: { lifecycle.snapshot },
            client: { captured in
                try lifecycle.validate(captured)
                return Client(serverURL: URL(string: "https://api.example.org")!, transport: http)
            },
            validate: { try lifecycle.validate($0) }
        ), configuredRedirect: { Self.redirect })
    }
}
