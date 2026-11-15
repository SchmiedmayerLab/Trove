//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import CTroveDeliverySQLite
import Foundation
import TroveAPITypes


extension DeliveryJournal where Contract == TroveDeliveryContract {
    /// Commits the exact declaration before networking. Replays cannot replace its file, targets or measurement facts.
    public func prepareRecordingTransfer(
        recordingID: UUID, deliveryID: UUID, declaration: Components.Schemas.RecordingTransferDeclaration
    ) throws -> DeliveryRecordingTransfer {
        try Task.checkCancellation()
        return try database.transaction {
            let attempt = try loadAttempt(deliveryID)
            _ = try activeDeliverySource(attempt.commitment.sourceID)
            guard let file = attempt.recordings.first(where: { $0.id == recordingID }) else { throw JournalError.unknownDelivery }
            let commitment = try RecordingTransferCommitment(declaration)
            try RecordingTransferBinding.validate(commitment, file: file, bytes: attempt.bytes, targetIntent: attempt.commitment.targetIntent)
            return try retainRecordingDeclaration(commitment, recordingID: recordingID)
        }
    }

    /// Stages every recording declaration with its clinical payload and next cursor, or commits none of them.
    /// The declaration list follows payload order; each list must cover exactly that payload's recording paths.
    public func stage(
        from expected: Checkpoint,
        nextCursor: Data,
        payloads: [Payload],
        recordingDeclarations: [[Components.Schemas.RecordingTransferDeclaration]],
        observedDeletions: [UUID] = [],
        queryExhausted: Bool = false
    ) throws -> [UUID] {
        try stageRecordingPayloads(
            from: expected,
            nextCursor: nextCursor,
            payloads: payloads,
            recordingDeclarations: recordingDeclarations,
            observedDeletions: observedDeletions,
            queryExhausted: queryExhausted,
            finalizingDeliveries: { _ in }
        )
    }

    /// Adapter-specific evidence joins the same transaction after every recording commitment is bound.
    func stageRecordingPayloads(
        from expected: Checkpoint,
        nextCursor: Data,
        payloads: [Payload],
        recordingDeclarations: [[Components.Schemas.RecordingTransferDeclaration]],
        observedDeletions: [UUID] = [],
        queryExhausted: Bool = false,
        finalizingDeliveries: ([UUID]) throws -> Void
    ) throws -> [UUID] {
        guard recordingDeclarations.count == payloads.count else { throw JournalError.invalidConfiguration }
        let commitments = try zip(payloads, recordingDeclarations).map { payload, declarations in
            guard declarations.count == payload.recordings.count,
                  Set(declarations.map(\.attachmentPath)) == Set(payload.recordings.map(\.relativePath)) else {
                throw JournalError.eventIdentityMismatch
            }
            return try declarations.map(RecordingTransferCommitment.init)
        }
        return try stage(
            from: expected, nextCursor: nextCursor, payloads: payloads, observedDeletions: observedDeletions, queryExhausted: queryExhausted
        ) { ids in
            for (index, id) in ids.enumerated() where !commitments[index].isEmpty {
                let files = try recordingReferences(for: id)
                let targets = try EventTargetIntent(targets: payloads[index].targets)
                for commitment in commitments[index] {
                    guard let file = files.first(where: { $0.relativePath == commitment.declaration.attachmentPath }) else {
                        throw JournalError.corruptJournal
                    }
                    try RecordingTransferBinding.validate(commitment, file: file, bytes: payloads[index].bytes, targetIntent: targets)
                    _ = try retainRecordingDeclaration(commitment, recordingID: file.id)
                }
            }
            try finalizingDeliveries(ids)
        }
    }

    private func retainRecordingDeclaration(_ commitment: RecordingTransferCommitment, recordingID: UUID) throws -> DeliveryRecordingTransfer {
        if let existing = try recordingTransfer(for: recordingID) {
            guard existing.commitment.serialized == commitment.serialized else { throw JournalError.eventIdentityMismatch }
            return existing
        }
        try database.execute("INSERT INTO recording_transfer(recording_id, declaration, declaration_sha256) VALUES (?, ?, ?)", [
            .text(recordingID.uuidString.lowercased()), .blob(commitment.serialized), .text(commitment.sha256)
        ])
        try checkByteLimit()
        try Task.checkCancellation()
        guard let result = try recordingTransfer(for: recordingID) else { throw JournalError.corruptJournal }
        return result
    }

    /// Recovery remains available after local source revocation. Reading evidence does not authorize another upload.
    public func recordingTransfer(for recordingID: UUID) throws -> DeliveryRecordingTransfer? {
        let rows = try database.query("""
            SELECT files.source_id, transfer.declaration, transfer.declaration_sha256, transfer.registration, transfer.receipt,
                files.relative_path, files.byte_count, files.sha256, delivery.source_id, delivery.id, delivery.payload IS NOT NULL
            FROM recording_transfer transfer JOIN recording_file files ON files.id = transfer.recording_id
            JOIN delivery ON delivery.id = files.delivery_id WHERE recording_id = ?
            """, [.text(recordingID.uuidString.lowercased())]) { statement in
                let sourceID = try Self.identifier(statement, 0)
                let commitment = try RecordingTransferCommitment(
                    restoring: DeliverySQLite.blob(statement, 1), sha256: DeliverySQLite.text(statement, 2)
                )
                let registration = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : try JSONDecoder().decode(
                    Components.Schemas.RecordingTransferRegistration.self, from: DeliverySQLite.blob(statement, 3)
                )
                let receipt = sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : try JSONDecoder().decode(
                    Components.Schemas.RecordingTransferReceipt.self, from: DeliverySQLite.blob(statement, 4)
                )
                guard try sourceID == Self.identifier(statement, 8),
                      try commitment.declaration.attachmentPath == DeliverySQLite.text(statement, 5),
                      commitment.declaration.content.storedByteCount == sqlite3_column_int64(statement, 6),
                      try commitment.declaration.content.storedSHA256 == DeliverySQLite.text(statement, 7) else { throw JournalError.corruptJournal }
                if let registration { try commitment.verify(registration, sourceID: sourceID, transferID: recordingID) }
                if let receipt { try commitment.verify(receipt, sourceID: sourceID, transferID: recordingID) }
                let transfer = DeliveryRecordingTransfer(
                    sourceID: sourceID, transferID: recordingID, commitment: commitment, registration: registration, receipt: receipt
                )
                return (transfer, try Self.identifier(statement, 9), sqlite3_column_int64(statement, 10) == 1)
        }
        guard let (transfer, deliveryID, pending) = rows.first else {
            return nil
        }
        if pending {
            let attempt = try loadAttempt(deliveryID)
            guard let file = attempt.recordings.first(where: { $0.id == recordingID }) else { throw JournalError.corruptJournal }
            try RecordingTransferBinding.validate(
                transfer.commitment, file: file, bytes: attempt.bytes, targetIntent: attempt.commitment.targetIntent
            )
        }
        return transfer
    }

    /// Retains only an acknowledgement of the exact declaration, source, transfer and stored bytes.
    public func recordRecordingRegistration(_ registration: Components.Schemas.RecordingTransferRegistration, for recordingID: UUID) throws {
        try Task.checkCancellation()
        try database.transaction {
            guard let transfer = try recordingTransfer(for: recordingID) else { throw JournalError.unknownDelivery }
            try transfer.commitment.verify(registration, sourceID: transfer.sourceID, transferID: recordingID)
            if let existing = transfer.registration {
                guard existing == registration else { throw JournalError.receiptConflict }
                return
            }
            try requirePendingRecording(recordingID)
            let bytes = try JSONEncoder().encode(registration)
            guard bytes.count <= 4096 else { throw JournalError.invalidConfiguration }
            try database.execute("UPDATE recording_transfer SET registration = ? WHERE recording_id = ?", [
                .blob(bytes), .text(recordingID.uuidString.lowercased())
            ])
            try checkByteLimit()
            try Task.checkCancellation()
        }
    }

    /// A newer upload may replace expired artifact evidence. It never releases the queued file.
    public func recordRecordingReceipt(_ receipt: Components.Schemas.RecordingTransferReceipt, for recordingID: UUID) throws {
        try Task.checkCancellation()
        try database.transaction {
            guard let transfer = try recordingTransfer(for: recordingID) else { throw JournalError.unknownDelivery }
            try transfer.commitment.verify(receipt, sourceID: transfer.sourceID, transferID: recordingID)
            if let existing = transfer.receipt {
                if existing == receipt {
                    return
                }
                guard receipt.verifiedAt >= existing.expiresAt, receipt.artifactId != existing.artifactId else {
                    throw JournalError.receiptConflict
                }
            }
            try requirePendingRecording(recordingID)
            let bytes = try JSONEncoder().encode(receipt)
            guard bytes.count <= 4096 else { throw JournalError.invalidConfiguration }
            try database.execute("UPDATE recording_transfer SET receipt = ? WHERE recording_id = ?", [
                .blob(bytes), .text(recordingID.uuidString.lowercased())
            ])
            try checkByteLimit()
            try Task.checkCancellation()
        }
    }

    private func requirePendingRecording(_ recordingID: UUID) throws {
        let pending = try database.query("""
            SELECT files.id FROM recording_file files JOIN delivery ON delivery.id = files.delivery_id
            WHERE files.id = ? AND files.state = 'attached' AND delivery.receipt IS NULL
            """, [.text(recordingID.uuidString.lowercased())]) { try Self.identifier($0, 0) }
        guard pending == [recordingID] else { throw JournalError.receiptConflict }
    }
}
