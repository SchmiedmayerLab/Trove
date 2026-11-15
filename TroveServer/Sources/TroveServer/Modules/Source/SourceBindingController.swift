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
        let registration = try await sourceInstallationService.register(
            registrationID: body.registrationID.requireId(),
            repositoryKind: SourceRepositoryKind(body.repositoryKind),
            credential: SourceInstallationCredential(base64: body.credentialBase64)
        )
        return try .ok(.init(body: .json(.init(registration))))
    }

    func getParticipantSourcesSourceId(
        _ input: Operations.GetParticipantSourcesSourceId.Input
    ) async throws -> Operations.GetParticipantSourcesSourceId.Output {
        let binding = try await sourceBindingService.find(id: input.path.sourceId.requireId())
        return try .ok(.init(body: .json(.init(binding))))
    }

    func postParticipantSourcesSourceIdRevoke(
        _ input: Operations.PostParticipantSourcesSourceIdRevoke.Input
    ) async throws -> Operations.PostParticipantSourcesSourceIdRevoke.Output {
        let binding = try await sourceBindingService.revoke(id: input.path.sourceId.requireId())
        return try .ok(.init(body: .json(.init(binding))))
    }
}


extension Components.Schemas.ParticipantSource {
    init(_ binding: SourceBinding) throws {
        guard binding.kind == .participantApp else { throw ServerError.notFound("Native source binding not found") }
        self.init(
            id: binding.id.uuidString.lowercased(),
            keyID: binding.keyID.uuidString.lowercased(),
            keyEpoch: binding.keyEpoch.rawValue,
            repositoryKind: try binding.repositoryKind.apiValue,
            repositoryScope: .init(system: binding.identifierRoot + "/repository", value: binding.repositoryKind.rawValue),
            kind: .participantApp,
            eventIdentifierSystem: binding.eventIdentifierSystem,
            identifierRoot: binding.identifierRoot,
            participantIdentifier: .init(system: binding.participantIdentifierSystem, value: binding.participantIdentifierValue),
            createdAt: binding.createdAt,
            revokedAt: binding.revokedAt
        )
    }
}
