// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import TroveAPIServer


extension Controller {
    func getParticipantProviderRegistrations(
        _ input: Operations.GetParticipantProviderRegistrations.Input
    ) async throws -> Operations.GetParticipantProviderRegistrations.Output {
        let values = try await providerRequest { try await providerRuntime.registrations.registrations() }
        return .ok(.init(headers: .init(cacheControl: "no-store"), body: .json(try values.map(Components.Schemas.ProviderRegistration.init))))
    }

    func getStudyCollectionProviderCapabilities(
        _ input: Operations.GetStudyCollectionProviderCapabilities.Input
    ) async throws -> Operations.GetStudyCollectionProviderCapabilities.Output {
        let values = try await providerRequest {
            try await providerRuntime.registrations.registrations(studyID: input.path.studyId.requireId())
        }
        return .ok(.init(headers: .init(cacheControl: "no-store"), body: .json(try values.map(Components.Schemas.ProviderRegistration.init))))
    }

    func startParticipantProviderLink(
        _ input: Operations.StartParticipantProviderLink.Input
    ) async throws -> Operations.StartParticipantProviderLink.Output {
        guard case .json(let body) = input.body else { throw ServerError.jsonBodyRequired }
        let value = try await providerRequest {
            try await providerConnections().start(registrationID: input.path.registrationId.requireId(), redirectID: body.redirectId)
        }
        return .ok(.init(headers: .init(cacheControl: "no-store"), body: .json(.init(
            id: value.id.uuidString.lowercased(),
            authorizationUrl: value.authorizationURL.absoluteString,
            redirectUri: value.redirectURI.absoluteString,
            expiresAt: value.expiresAt
        ))))
    }

    func completeParticipantProviderLink(
        _ input: Operations.CompleteParticipantProviderLink.Input
    ) async throws -> Operations.CompleteParticipantProviderLink.Output {
        guard case .json(let body) = input.body else { throw ServerError.jsonBodyRequired }
        let value = try await providerRequest {
            try await providerConnections().complete(id: input.path.intentId.requireId(), state: body.state, code: body.code)
        }
        return .ok(.init(headers: .init(cacheControl: "no-store"), body: .json(.init(value))))
    }

    func getParticipantProviderConnections(
        _ input: Operations.GetParticipantProviderConnections.Input
    ) async throws -> Operations.GetParticipantProviderConnections.Output {
        let values = try await providerRequest { try await providerConnections().statuses() }
        return .ok(.init(headers: .init(cacheControl: "no-store"), body: .json(values.map(Components.Schemas.ProviderConnection.init))))
    }

    func disconnectParticipantProviderConnection(
        _ input: Operations.DisconnectParticipantProviderConnection.Input
    ) async throws -> Operations.DisconnectParticipantProviderConnection.Output {
        let value = try await providerRequest {
            try await providerConnections().disconnect(id: input.path.connectionId.requireId())
        }
        return .ok(.init(headers: .init(cacheControl: "no-store"), body: .json(.init(value))))
    }

    private func providerConnections() throws -> ProviderConnectionService {
        _ = try AuthContext.checkIsParticipant()
        return try providerRuntime.requireConnections()
    }

    private func providerRequest<Value>(_ operation: () async throws -> Value) async throws -> Value {
        do { return try await operation() } catch let error as ProviderFailure {
            switch error {
            case .invalidLink, .invalidPayload: throw ServerError.badRequest("Provider request could not be accepted")
            case .fenced, .scopeLost: throw ServerError.notFound("Provider connection is unavailable")
            case .ambiguousAccount, .reauthorizationRequired: throw ServerError.conflict("A new provider authorization is required")
            case .capacityExceeded: throw ServerError(status: .tooManyRequests, title: "Too Many Requests", detail: "Try again later")
            case .unavailable:
                throw ServerError(status: .serviceUnavailable, title: "Service Unavailable", detail: "Provider integration is unavailable")
            case .invalidConfiguration: throw ServerError.unexpectedError
            }
        }
    }
}
