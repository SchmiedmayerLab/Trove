//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIServer


extension Controller {
    func postParticipantSources(
        _ input: Operations.PostParticipantSources.Input
    ) async throws -> Operations.PostParticipantSources.Output {
        guard case .json(let body) = input.body else {
            throw ServerError.jsonBodyRequired
        }
        let binding = try await sourceBindingService.register(registrationID: body.registrationID.requireId())
        return .ok(.init(body: .json(.init(binding))))
    }

    func getParticipantSourcesSourceId(
        _ input: Operations.GetParticipantSourcesSourceId.Input
    ) async throws -> Operations.GetParticipantSourcesSourceId.Output {
        let binding = try await sourceBindingService.find(id: input.path.sourceId.requireId())
        return .ok(.init(body: .json(.init(binding))))
    }

    func postParticipantSourcesSourceIdRevoke(
        _ input: Operations.PostParticipantSourcesSourceIdRevoke.Input
    ) async throws -> Operations.PostParticipantSourcesSourceIdRevoke.Output {
        let binding = try await sourceBindingService.revoke(id: input.path.sourceId.requireId())
        return .ok(.init(body: .json(.init(binding))))
    }
}


extension Components.Schemas.ParticipantSource {
    init(_ binding: SourceBinding) {
        let kind: KindPayload = switch binding.kind {
        case .participantApp: .participantApp
        }
        self.init(
            id: binding.id.uuidString.lowercased(),
            registrationID: binding.registrationID.uuidString.lowercased(),
            kind: kind,
            eventIdentifierSystem: binding.eventIdentifierSystem,
            identifierRoot: binding.identifierRoot,
            participantIdentifier: .init(system: binding.participantIdentifierSystem, value: binding.participantIdentifierValue),
            createdAt: binding.createdAt,
            revokedAt: binding.revokedAt
        )
    }
}
