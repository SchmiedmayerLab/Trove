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


enum ClinicalRecordingStore {
    /// Retention, immutable node binding, clinical custody and its audit must commit together.
    static func retain(
        _ attachments: [ClinicalRecordingAttachment], nodes: [String: UUID], source: SourceBinding, on database: any Database
    ) async throws {
        guard database.inTransaction, let sql = database as? any SQLDatabase else { throw ServerError.unexpectedError }
        for attachment in attachments {
            let reference = attachment.reference
            guard let nodeID = nodes[attachment.declaration.output.fullURL], reference.ownerID == source.participantID,
                  reference.purpose == .recording,
                  reference.scope == .participantSource(.init(participantID: source.participantID, sourceBindingID: source.id)) else {
                throw FHIRValidationClient.invalid
            }
            // This UPDATE fences cleanup. A ready object that expired during decoding cannot gain custody.
            let row = try await sql.raw("""
                UPDATE stored_artifacts SET state = 'retained', cleanup_after = NULL
                WHERE id = \(bind: reference.id) AND owner_id = \(bind: reference.ownerID) AND purpose = 'recording'
                  AND digest = \(bind: reference.digest) AND byte_count = \(bind: reference.byteCount)
                  AND \(reference.scope.matchingColumns)
                  AND (state = 'retained' OR (state = 'ready' AND expires_at > \(bind: Date())))
                RETURNING id
                """)
                .first()
            guard row != nil else {
                throw ServerError(
                    status: .serviceUnavailable, title: "Recording Unavailable", detail: "Renew the expired transfer and retry the record"
                )
            }
            try await sql.raw("""
                INSERT INTO clinical_recording_attachments (node_id, artifact_id, attachment_path, content_evidence)
                VALUES (\(bind: nodeID), \(bind: reference.id), \(bind: attachment.declaration.attachmentPath),
                        \(bind: try attachment.content.serialized))
                """)
                .run()
        }
    }
}
