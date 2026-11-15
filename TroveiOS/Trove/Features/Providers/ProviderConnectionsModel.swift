//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Grove
import Observation
import TroveAPIClient


@MainActor
@Observable
final class ProviderConnectionsModel: Module, EnvironmentAccessible {
    enum Failure: Error { case unavailable, invalidAuthorization }

    struct Transport {
        var session: @MainActor () -> KeycloakSessionSnapshot?
        var client: @MainActor (KeycloakSessionSnapshot) throws -> Client
        var validate: @MainActor (KeycloakSessionSnapshot) throws -> Void
    }

    @ObservationIgnored @Dependency(TroveAPIModule.self) private var api
    @ObservationIgnored private let transport: Transport?
    @ObservationIgnored private let configuredRedirect: @MainActor () -> URL?
    private var loadedSession: KeycloakSessionSnapshot?
    private var operationSession: KeycloakSessionSnapshot?
    private var operationID: UUID?
    private var storedRegistrations: [Components.Schemas.ProviderRegistration] = []
    private var storedConnections: [Components.Schemas.ProviderConnection] = []
    private var storedFailure = false

    var sessionSnapshot: KeycloakSessionSnapshot? {
        if let transport {
            return transport.session()
        }
        return api.sessionSnapshot
    }
    var registrations: [Components.Schemas.ProviderRegistration] { loadedSession == sessionSnapshot ? storedRegistrations : [] }
    var connections: [Components.Schemas.ProviderConnection] { loadedSession == sessionSnapshot ? storedConnections : [] }
    var hasFailed: Bool { loadedSession == sessionSnapshot && storedFailure }
    var isBusy: Bool { operationSession == sessionSnapshot && operationID != nil }

    init(transport: Transport? = nil, configuredRedirect: @escaping @MainActor () -> URL? = { Config.providerRedirectURI }) {
        self.transport = transport
        self.configuredRedirect = configuredRedirect
    }

    func refresh() async {
        await perform { client, session in
            async let registrations = client.getParticipantProviderRegistrations(.init()).ok.body.json
            async let connections = client.getParticipantProviderConnections(.init()).ok.body.json
            let values = try await (registrations, connections)
            try self.validate(session)
            try Task.checkCancellation()
            self.storedRegistrations = values.0
            self.storedConnections = values.1
        }
    }

    func connect(
        registration: Components.Schemas.ProviderRegistration,
        redirect: Components.Schemas.ProviderRedirect,
        authenticate: @MainActor (URL, URL) async throws -> URL
    ) async {
        await perform { client, session in
            guard registration.redirects.contains(redirect),
                  let redirectURL = URL(string: redirect.uri), redirectURL == self.configuredRedirect() else { throw Failure.unavailable }
            _ = try ProviderAuthorizationCallback.redirectComponents(redirectURL)
            let intent = try await client.startParticipantProviderLink(.init(
                path: .init(registrationId: registration.id), body: .json(.init(redirectId: redirect.id))
            )).ok.body.json
            try self.validate(session)
            try Task.checkCancellation()
            guard intent.redirectUri == redirectURL.absoluteString, intent.expiresAt > .now,
                  let authorization = URL(string: intent.authorizationUrl),
                  let components = URLComponents(url: authorization, resolvingAgainstBaseURL: false),
                  components.scheme == "https", components.host != nil,
                  components.user == nil, components.password == nil, components.fragment == nil else { throw Failure.invalidAuthorization }
            let callbackURL = try await authenticate(authorization, redirectURL)
            try self.validate(session)
            try Task.checkCancellation()
            guard intent.expiresAt > .now else { throw Failure.invalidAuthorization }
            let callback = try ProviderAuthorizationCallback(url: callbackURL, redirect: redirectURL)
            let connection = try await client.completeParticipantProviderLink(.init(
                path: .init(intentId: intent.id), body: .json(.init(state: callback.state, code: callback.code))
            )).ok.body.json
            try self.validate(session)
            try Task.checkCancellation()
            self.store(connection)
        }
    }

    func disconnect(_ connection: Components.Schemas.ProviderConnection) async {
        await perform { client, session in
            let updated = try await client.disconnectParticipantProviderConnection(.init(path: .init(connectionId: connection.id))).ok.body.json
            try self.validate(session)
            try Task.checkCancellation()
            self.store(updated)
        }
    }

    private func client(for session: KeycloakSessionSnapshot) throws -> Client {
        if let transport {
            return try transport.client(session)
        }
        return try api.requireClient(for: session)
    }

    private func validate(_ session: KeycloakSessionSnapshot) throws {
        if let transport { try transport.validate(session) } else { try api.validateSession(session) }
    }

    private func store(_ connection: Components.Schemas.ProviderConnection) {
        storedConnections.removeAll { $0.id == connection.id }
        storedConnections.append(connection)
    }

    private func perform(_ action: (Client, KeycloakSessionSnapshot) async throws -> Void) async {
        guard let session = sessionSnapshot, !isBusy else {
            return
        }
        let identifier = UUID()
        operationID = identifier
        operationSession = session
        if loadedSession != session { storedRegistrations = []; storedConnections = [] }
        loadedSession = session
        storedFailure = false
        defer {
            if operationID == identifier { operationID = nil; operationSession = nil }
        }
        do {
            try await action(client(for: session), session)
        } catch {
            guard sessionSnapshot == session, operationID == identifier, !Task.isCancelled else {
                return
            }
            if !(error is CancellationError) { storedFailure = true }
        }
    }
}
