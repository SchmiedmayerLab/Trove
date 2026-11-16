//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import GroveFHIRContract
import ModelsR4
import class OpenAPIRuntime.HTTPBody
import SQLKit
import TroveAPITypes


extension RecordingTransferService {
    /// Authorization precedes object reads; clinical admission repeats it under the custody transaction's locks.
    func verifyAttachments(
        _ bindings: [Components.Schemas.RecordingAttachmentBinding],
        bytes: Data,
        source: SourceBinding,
        targets: [ClinicalEventTarget],
        installation: SourceInstallationProof
    ) async throws -> [ClinicalRecordingAttachment] {
        guard !bindings.isEmpty else {
            return []
        }
        guard bindings.count <= 16, Set(bindings.map(\.attachmentPath)).count == bindings.count,
              Set(try bindings.map { try $0.transferId.requireId() }).count == bindings.count,
              Set(try bindings.map { try $0.artifactId.requireId() }).count == bindings.count else { throw FHIRValidationClient.invalid }
        guard let graph = try? ExchangeGraph(validating: bytes, kind: .active) else { throw FHIRValidationClient.invalid }
        let authorization = Authorization(sourceID: source.id, installation: installation, context: try AuthContext.checkIsParticipant())
        var result: [ClinicalRecordingAttachment] = []
        for binding in bindings {
            let (reference, declaration) = try await resolve(binding, source: source)
            guard let entry = graph.bundle.entry?.first(where: { $0.fullUrl?.value?.url.absoluteString == declaration.output.fullURL }),
                  case .documentReference(let document)? = entry.resource else { throw FHIRValidationClient.invalid }
            try ClinicalRecordingAttachment.validate(document: document, declaration: declaration)
            let selected = targets.compactMap { target -> ClinicalEventTarget? in
                target.outputFullURLs.contains(declaration.output.fullURL)
                    ? .init(consentID: target.consentID, outputFullURLs: [declaration.output.fullURL]) : nil
            }
            guard try ClinicalEventIntent(targets: selected).serialized == declaration.intent.serialized else {
                throw ServerError.badRequest("Recording targets do not match the clinical record")
            }
            _ = try await database.transaction { transaction in
                try await self.authorize(authorization, declaration: declaration, now: Date(), on: transaction)
            }
            let body = try await recordingBody(reference)
            let content = try await RecordingContentVerification.verify(body, declaration: declaration, maximumWindowByteCount: 8 * 1024 * 1024)
            let attachment = ClinicalRecordingAttachment(reference: reference, declaration: declaration, content: content)
            _ = try FHIRRecordingProjection.routeBounds(document, external: attachment)
            result.append(attachment)
        }
        return result
    }

    private func recordingBody(_ reference: ArtifactReference) async throws -> HTTPBody {
        do {
            return try await storage.downloadBody(key: reference.key, maximumBytes: reference.byteCount)
        } catch {
            try _Concurrency.Task.checkCancellation()
            if error is CancellationError { throw CancellationError() }
            throw ServerError(status: .serviceUnavailable, title: "Recording Unavailable", detail: "Retry the unchanged record")
        }
    }

    private func resolve(
        _ binding: Components.Schemas.RecordingAttachmentBinding, source: SourceBinding
    ) async throws -> (ArtifactReference, RecordingTransferDeclaration) {
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        let artifactID = try binding.artifactId.requireId(), transferID = try binding.transferId.requireId()
        guard let row = try await sql.raw("""
            SELECT transfers.transfer_id, transfers.declaration, transfers.declaration_sha256, receipts.*
            FROM recording_transfers transfers
            JOIN recording_transfer_attempts attempts ON attempts.transfer_row_id = transfers.id
            JOIN recording_transfer_receipts receipts ON receipts.artifact_id = attempts.artifact_id
            WHERE transfers.source_id = \(bind: source.id) AND transfers.transfer_id = \(bind: transferID)
              AND receipts.artifact_id = \(bind: artifactID)
            """)
                .first(), let artifact = try await StoredArtifact.find(artifactID, on: database) else {
            throw ServerError.notFound("Recording attachment not found")
        }
        let declaration = try RecordingTransferDeclaration(
            restoring: row.decode(column: "declaration", as: String.self), digest: row.decode(column: "declaration_sha256", as: String.self)
        )
        let receipt = try RecordingTransferReceipt(row: row), reference = try artifact.reference()
        guard binding.attachmentPath == declaration.attachmentPath,
              reference.purpose == .recording, reference.ownerID == source.participantID,
              reference.scope == .participantSource(.init(participantID: source.participantID, sourceBindingID: source.id)),
              reference.digest == receipt.storedSHA256, reference.digest == declaration.content.storedSHA256,
              reference.byteCount == receipt.storedByteCount, reference.byteCount == declaration.content.storedByteCount,
              reference.byteCount <= limits.storedBytes, declaration.content.sourceByteCount <= limits.sourceBytes else {
            throw ServerError.conflict("Recording attachment does not match its declaration")
        }
        guard artifact.state == .retained || (artifact.state == .ready && artifact.expiresAt > Date() && receipt.expiresAt > Date()) else {
            throw ServerError(status: .serviceUnavailable, title: "Recording Unavailable", detail: "Renew the expired transfer and retry the record")
        }
        return (reference, declaration)
    }
}
