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


/// All writes run under the participant lock. No object bytes or credentials are stored here.
struct RecordingTransferStore {
    struct Attempt {
        let artifactID: UUID
        let number: Int
        let leaseExpiresAt: Date
    }

    let sql: any SQLDatabase

    func declarationID(sourceID: UUID, transferID: UUID, declaration: RecordingTransferDeclaration, now: Date) async throws -> UUID {
        if let row = try await sql.raw("""
            SELECT id, declaration FROM recording_transfers
            WHERE source_id = \(bind: sourceID) AND transfer_id = \(bind: transferID)
            """)
            .first() {
            guard try row.decode(column: "declaration", as: String.self) == declaration.serialized else {
                throw ServerError.conflict("Transfer identity is already bound to a different declaration")
            }
            return try row.decode(column: "id", as: UUID.self)
        }
        let id = UUID()
        try await sql.raw("""
            INSERT INTO recording_transfers (id, source_id, transfer_id, declaration, declaration_sha256, created_at)
            VALUES (\(bind: id), \(bind: sourceID), \(bind: transferID), \(bind: declaration.serialized), \(bind: declaration.sha256), \(bind: now))
            """)
            .run()
        return id
    }

    func latestAttempt(for declarationID: UUID) async throws -> Attempt? {
        guard let row = try await sql.raw("""
            SELECT artifact_id, attempt_number, lease_expires_at FROM recording_transfer_attempts
            WHERE transfer_row_id = \(bind: declarationID) ORDER BY attempt_number DESC LIMIT 1
            """)
            .first() else { return nil }
        return try .init(
            artifactID: row.decode(column: "artifact_id", as: UUID.self),
            number: row.decode(column: "attempt_number", as: Int.self),
            leaseExpiresAt: row.decode(column: "lease_expires_at", as: Date.self)
        )
    }

    func insertAttempt(artifactID: UUID, declarationID: UUID, number: Int, leaseExpiresAt: Date) async throws {
        try await sql.raw("""
            INSERT INTO recording_transfer_attempts (artifact_id, transfer_row_id, attempt_number, lease_expires_at)
            VALUES (\(bind: artifactID), \(bind: declarationID), \(bind: number), \(bind: leaseExpiresAt))
            """)
            .run()
    }

    func receipt(sourceID: UUID, transferID: UUID) async throws -> RecordingTransferReceipt? {
        // Inspect only the latest attempt: a superseded receipt cannot complete a newer upload.
        let row = try await sql.raw("""
            SELECT transfers.transfer_id, transfers.declaration_sha256, receipts.*
            FROM recording_transfers transfers
            JOIN recording_transfer_attempts attempts ON attempts.transfer_row_id = transfers.id
            JOIN recording_transfer_receipts receipts ON receipts.artifact_id = attempts.artifact_id
            WHERE transfers.source_id = \(bind: sourceID) AND transfers.transfer_id = \(bind: transferID)
              AND attempts.attempt_number = (
                SELECT MAX(latest.attempt_number) FROM recording_transfer_attempts latest WHERE latest.transfer_row_id = transfers.id
              )
            """)
            .first()
        return try row.map(RecordingTransferReceipt.init)
    }

    func insertReceipt(reference: ArtifactReference, verifiedAt: Date, expiresAt: Date) async throws {
        try await sql.raw("""
            INSERT INTO recording_transfer_receipts (artifact_id, stored_byte_count, stored_sha256, verified_at, expires_at)
            VALUES (\(bind: reference.id), \(bind: reference.byteCount), \(bind: reference.digest), \(bind: verifiedAt), \(bind: expiresAt))
            """)
            .run()
    }
}
