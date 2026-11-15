//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPITypes


extension RecordingTransferDrainer {
    func lookup(_ transfer: DeliveryRecordingTransfer) async throws -> Components.Schemas.RecordingTransferReceipt? {
        let response = try await request {
            try await client.lookupParticipantRecordingTransferReceipt(.init(
                path: .init(sourceId: transfer.sourceID.uuidString.lowercased(), transferId: transfer.transferID.uuidString.lowercased())
            ))
        }
        switch response {
        case .ok(let value): return try value.body.json
        case .notFound: return nil
        case .badRequest: try rejected(400)
        case .unauthorized: try rejected(401)
        case .forbidden: try rejected(403)
        case .conflict: try rejected(409)
        case .internalServerError: try rejected(500)
        case .undocumented(let code, _): try rejected(code)
        }
    }

    func register(
        _ transfer: DeliveryRecordingTransfer, installationID: UUID, credential: String
    ) async throws -> Components.Schemas.RecordingTransferRegistration {
        let response = try await request {
            try await client.declareParticipantRecordingTransfer(.init(
                path: .init(sourceId: transfer.sourceID.uuidString.lowercased(), transferId: transfer.transferID.uuidString.lowercased()),
                headers: .init(troveSourceInstallationID: installationID.uuidString.lowercased(), troveSourceCredential: credential),
                body: .json(transfer.commitment.declaration)
            ))
        }
        switch response {
        case .ok(let value): return try value.body.json
        case .badRequest: try rejected(400)
        case .unauthorized: try rejected(401)
        case .forbidden: try rejected(403)
        case .notFound: try rejected(404)
        case .conflict: try rejected(409)
        case .contentTooLarge: try rejected(413)
        case .internalServerError: try rejected(500)
        case .serviceUnavailable: try rejected(503)
        case .undocumented(let code, _): try rejected(code)
        }
    }

    func upload(
        _ transfer: DeliveryRecordingTransfer, body: RecordingUploadBody, installationID: UUID, credential: String
    ) async throws -> Components.Schemas.RecordingTransferReceipt {
        let response = try await request {
            try await client.uploadParticipantRecordingTransfer(.init(
                path: .init(sourceId: transfer.sourceID.uuidString.lowercased(), transferId: transfer.transferID.uuidString.lowercased()),
                headers: .init(troveSourceInstallationID: installationID.uuidString.lowercased(), troveSourceCredential: credential),
                body: .binary(body.body)
            ))
        }
        switch response {
        case .ok(let value): return try value.body.json
        case .badRequest: try rejected(400)
        case .unauthorized: try rejected(401)
        case .forbidden: try rejected(403)
        case .notFound: try rejected(404)
        case .conflict: try rejected(409)
        case .contentTooLarge: try rejected(413)
        case .internalServerError: try rejected(500)
        case .serviceUnavailable: try rejected(503)
        case .undocumented(let code, _): try rejected(code)
        }
    }

    private func request<Result: Sendable>(_ operation: () async throws -> Result) async throws -> Result {
        try await checkSession()
        let result: Result
        do {
            result = try await operation()
        } catch {
            try await checkSession()
            throw Failure.transportFailed
        }
        try await checkSession()
        return result
    }
}
