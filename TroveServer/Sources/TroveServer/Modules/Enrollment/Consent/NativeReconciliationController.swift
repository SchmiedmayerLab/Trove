//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import TroveAPIServer


extension Controller {
    func requestParticipantCollectionReconciliations(
        _ input: Operations.RequestParticipantCollectionReconciliations.Input
    ) async throws -> Operations.RequestParticipantCollectionReconciliations.Output {
        _ = try AuthContext.checkIsParticipant()
        guard case .json(let body) = input.body else { throw ServerError.invalidRequestBody }
        let instructions = try await consentService.nativeReconciliations(
            enrollmentID: input.path.enrollmentId.requireId(),
            sourceID: body.sourceId.requireId(),
            proof: .init(registrationID: input.headers.troveSourceInstallationID, credentialBase64: input.headers.troveSourceCredential),
            configuration: nativeReconciliationSettings
        )
        return .ok(.init(headers: .init(cacheControl: .noStore), body: .json(.init(instructions: instructions))))
    }

    func completeParticipantCollectionReconciliation(
        _ input: Operations.CompleteParticipantCollectionReconciliation.Input
    ) async throws -> Operations.CompleteParticipantCollectionReconciliation.Output {
        _ = try AuthContext.checkIsParticipant()
        guard case .json(let body) = input.body else { throw ServerError.invalidRequestBody }
        try await consentService.completeNativeReconciliation(
            enrollmentID: input.path.enrollmentId.requireId(),
            sourceID: body.sourceId.requireId(),
            id: input.path.reconciliationId.requireId(),
            proof: .init(registrationID: input.headers.troveSourceInstallationID, credentialBase64: input.headers.troveSourceCredential)
        )
        return .noContent(.init(headers: .init(cacheControl: .noStore)))
    }
}
