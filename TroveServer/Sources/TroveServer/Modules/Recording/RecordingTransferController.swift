//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import TroveAPIServer


extension Controller {
    func declareParticipantRecordingTransfer(
        _ input: Operations.DeclareParticipantRecordingTransfer.Input
    ) async throws -> Operations.DeclareParticipantRecordingTransfer.Output {
        _ = try AuthContext.checkIsParticipant()
        guard case .json(let body) = input.body else { throw ServerError.invalidRequestBody }
        let registration = try await recordingTransferService.register(
            sourceID: input.path.sourceId.requireId(),
            transferID: input.path.transferId.requireId(),
            declaration: .init(body),
            installation: .init(registrationID: input.headers.troveSourceInstallationID, credentialBase64: input.headers.troveSourceCredential)
        )
        return .ok(.init(body: .json(registration)))
    }

    func uploadParticipantRecordingTransfer(
        _ input: Operations.UploadParticipantRecordingTransfer.Input
    ) async throws -> Operations.UploadParticipantRecordingTransfer.Output {
        _ = try AuthContext.checkIsParticipant()
        guard case .binary(let body) = input.body else { throw ServerError.invalidRequestBody }
        let sourceID = try input.path.sourceId.requireId()
        let receipt = try await recordingTransferService.uploadRegistered(
            body,
            sourceID: sourceID,
            transferID: input.path.transferId.requireId(),
            installation: .init(registrationID: input.headers.troveSourceInstallationID, credentialBase64: input.headers.troveSourceCredential)
        )
        return .ok(.init(body: .json(receipt.apiRepresentation(sourceID: sourceID))))
    }

    func lookupParticipantRecordingTransferReceipt(
        _ input: Operations.LookupParticipantRecordingTransferReceipt.Input
    ) async throws -> Operations.LookupParticipantRecordingTransferReceipt.Output {
        _ = try AuthContext.checkIsParticipant()
        let sourceID = try input.path.sourceId.requireId()
        let receipt = try await recordingTransferService.lookup(sourceID: sourceID, transferID: input.path.transferId.requireId())
        return .ok(.init(body: .json(receipt.apiRepresentation(sourceID: sourceID))))
    }
}


extension RecordingTransferDeclaration {
    init(_ value: Components.Schemas.RecordingTransferDeclaration) throws {
        guard let format = RegisteredRecordingFormat(rawValue: value.format),
              let storedCount = Int(exactly: value.content.storedByteCount), let sourceCount = Int(exactly: value.content.sourceByteCount) else {
            throw ServerError.badRequest("Unsupported recording format or byte count")
        }
        let encoding: Encoding = switch value.content.encoding {
        case .identity: .identity
        case .zstd: .zstd
        }
        try self.init(
            attachmentPath: value.attachmentPath,
            outputFullURL: value.outputFullUrl,
            profile: value.profile,
            format: format,
            effectiveAt: value.effectiveAt,
            effectiveEnd: value.effectiveEnd,
            content: .init(
                storedByteCount: storedCount,
                storedSHA256: value.content.storedSHA256,
                sourceByteCount: sourceCount,
                sourceSHA256: value.content.sourceSHA256,
                encoding: encoding
            ),
            targets: value.targets.map { try $0.domainTarget }
        )
    }
}


extension RecordingTransferReceipt {
    func apiRepresentation(sourceID: UUID) -> Components.Schemas.RecordingTransferReceipt {
        .init(
            sourceId: sourceID.uuidString.lowercased(),
            transferId: transferID.uuidString.lowercased(),
            artifactId: artifactID.uuidString.lowercased(),
            declarationSHA256: declarationSHA256,
            storedByteCount: Int64(storedByteCount),
            storedSHA256: storedSHA256,
            verifiedAt: verifiedAt,
            expiresAt: expiresAt
        )
    }
}
