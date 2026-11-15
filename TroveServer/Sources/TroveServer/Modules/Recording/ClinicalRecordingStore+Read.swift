//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import SQLKit


extension ClinicalRecordingStore {
    private static var unavailable: ServerError {
        .internalServerError("Retained recording is unavailable")
    }

    /// Reads immutable admission evidence, without reading recording bytes or granting access.
    /// Callers must hold the study disclosure fence and commit its audit before returning a view.
    static func retained(eventID: UUID, on database: any Database) async throws -> [ClinicalRecordingAttachment] {
        guard database.inTransaction, let sql = database as? any SQLDatabase else { throw AuditError.transactionRequired }
        let rows = try await sql.raw("""
            SELECT bindings.attachment_path, bindings.content_evidence, nodes.full_url, nodes.source_id,
                sources.participant_id, transfers.transfer_id, transfers.declaration, transfers.declaration_sha256, receipts.*
            FROM clinical_recording_attachments bindings
            JOIN clinical_event_nodes nodes ON nodes.id = bindings.node_id
            JOIN source_bindings sources ON sources.id = nodes.source_id
            JOIN recording_transfer_receipts receipts ON receipts.artifact_id = bindings.artifact_id
            JOIN recording_transfer_attempts attempts ON attempts.artifact_id = receipts.artifact_id
            JOIN recording_transfers transfers ON transfers.id = attempts.transfer_row_id AND transfers.source_id = nodes.source_id
            WHERE nodes.event_id = \(bind: eventID)
            ORDER BY nodes.ordinal
            """)
            .all()
        guard rows.count <= 16 else { throw unavailable }
        var attachments: [ClinicalRecordingAttachment] = []
        for row in rows {
            let receipt = try RecordingTransferReceipt(row: row)
            let declaration = try RecordingTransferDeclaration(
                restoring: row.decode(column: "declaration", as: String.self), digest: receipt.declarationSHA256
            )
            let participantID = try row.decode(column: "participant_id", as: UUID.self)
            let sourceID = try row.decode(column: "source_id", as: UUID.self)
            guard let artifact = try await StoredArtifact.find(receipt.artifactID, on: database), artifact.state == .retained else {
                throw unavailable
            }
            let reference = try artifact.reference()
            guard reference.purpose == .recording, reference.ownerID == participantID,
                  reference.scope == .participantSource(.init(participantID: participantID, sourceBindingID: sourceID)),
                  reference.digest == receipt.storedSHA256, reference.digest == declaration.content.storedSHA256,
                  reference.byteCount == receipt.storedByteCount, reference.byteCount == declaration.content.storedByteCount,
                  declaration.attachmentPath == (try row.decode(column: "attachment_path", as: String.self)),
                  declaration.output.fullURL == (try row.decode(column: "full_url", as: String.self)) else { throw unavailable }
            attachments.append(.init(
                reference: reference,
                declaration: declaration,
                content: try .init(restoring: row.decode(column: "content_evidence", as: String.self))
            ))
        }
        return attachments
    }
}
