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


extension RecordingTransferService {
    /// Mark only this failed transport attempt; never discard accepted custody or a committed receipt.
    func abandon(_ attempt: Attempt) async throws {
        let context = try AuthContext.checkIsParticipant()
        guard case .participantSource(let scope) = attempt.reference.scope else { throw ServerError.unexpectedError }
        try await database.transaction { transaction in
            let source = try await ClinicalEventStore(database: transaction).lockSourceOwner(
                sourceID: scope.sourceBindingID, context: context, on: transaction, requireActive: false
            )
            guard source.participantID == scope.participantID, let sql = transaction as? any SQLDatabase else {
                throw ServerError.unexpectedError
            }
            let row = try await sql.raw("""
                UPDATE stored_artifacts SET state = 'discarding', cleanup_after = \(bind: Date())
                WHERE id = \(bind: attempt.reference.id) AND purpose = 'recording' AND state IN ('staging', 'ready')
                  AND \(attempt.reference.scope.matchingColumns)
                  AND EXISTS (SELECT 1 FROM recording_transfer_attempts attempts
                    WHERE attempts.artifact_id = stored_artifacts.id AND attempts.transfer_row_id = \(bind: attempt.declarationID))
                  AND NOT EXISTS (SELECT 1 FROM recording_transfer_receipts receipts WHERE receipts.artifact_id = stored_artifacts.id)
                  AND NOT EXISTS (SELECT 1 FROM clinical_recording_attachments WHERE artifact_id = stored_artifacts.id)
                RETURNING id
                """)
                .first()
            if row != nil {
                try await AuditRepository.recordMutation(.init(
                    context: context.auditContext,
                    action: .recordingArtifactDiscardScheduled,
                    scope: attempt.reference.scope.auditScope,
                    target: .init(id: attempt.reference.id)
                ), on: transaction)
            }
        }
    }
}
