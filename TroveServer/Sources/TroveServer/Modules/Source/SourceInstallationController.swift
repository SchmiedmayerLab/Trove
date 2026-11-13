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
    func getParticipantSourceInstallation(
        _ input: Operations.GetParticipantSourceInstallation.Input
    ) async throws -> Operations.GetParticipantSourceInstallation.Output {
        let registration = try await sourceInstallationService.find(registrationID: input.path.registrationId.requireId())
        return .ok(.init(body: .json(.init(registration))))
    }

    func revokeParticipantSourceInstallation(
        _ input: Operations.RevokeParticipantSourceInstallation.Input
    ) async throws -> Operations.RevokeParticipantSourceInstallation.Output {
        let registration = try await sourceInstallationService.revoke(registrationID: input.path.registrationId.requireId())
        return .ok(.init(body: .json(.init(registration))))
    }

    func recoverParticipantSourceIdentity(
        _ input: Operations.RecoverParticipantSourceIdentity.Input
    ) async throws -> Operations.RecoverParticipantSourceIdentity.Output {
        guard case .json(let body) = input.body else { throw ServerError.jsonBodyRequired }
        let recovered = try await sourceInstallationService.recover(
            registrationID: input.path.registrationId.requireId(), credential: SourceInstallationCredential(base64: body.credentialBase64)
        )
        return .ok(.init(
            headers: .init(cacheControl: "no-store"),
            body: .json(.init(
                registration: .init(recovered.registration),
                identityKeyBase64: recovered.identity.key.withUnsafeBytes { Data($0).base64EncodedString() }
            ))
        ))
    }
}


extension Components.Schemas.ParticipantSourceRegistration {
    init(_ registration: SourceInstallationService.Registration) {
        self.init(
            source: .init(registration.source),
            installation: .init(
                registrationID: registration.installation.registrationID.uuidString.lowercased(),
                sourceID: registration.installation.sourceID.uuidString.lowercased(),
                createdAt: registration.installation.createdAt,
                revokedAt: registration.installation.revokedAt
            )
        )
    }
}


extension SourceRepositoryKind {
    var apiValue: Components.Schemas.NativeSourceRepository {
        switch self {
        case .healthKit: .healthkit
        case .sensorKit: .sensorkit
        }
    }

    init(_ value: Components.Schemas.NativeSourceRepository) {
        self = switch value {
        case .healthkit: .healthKit
        case .sensorkit: .sensorKit
        }
    }
}
