//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Fluent
import Foundation
import SQLKit


/// Storage mechanics only. Domain services authorize the owner and purpose before calling.
struct ArtifactStore: Sendable {
    enum Failure: Error {
        case transactionRequired, operationInsideTransaction, invalidCleanupBatch, unsupportedDatabase
    }

    let database: any Database
    let storage: ObjectStorageService

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func stage(
        _ data: Data, purpose: ArtifactReference.Purpose, ownerID: UUID, scope: StudyArtifactScope, now: Date = Date()
    ) async throws -> ArtifactReference {
        guard !database.inTransaction else { throw Failure.operationInsideTransaction }
        guard !data.isEmpty, data.count <= purpose.maximumBytes else {
            throw ServerError.badRequest("Artifact exceeds the supported size limit")
        }
        let reference = ArtifactReference(id: UUID(), ownerID: ownerID, purpose: purpose, digest: Self.digest(data), byteCount: data.count)
        let record = StoredArtifact(reference: reference, scope: scope, expiresAt: now.addingTimeInterval(3600))
        // Commit the recovery locator before any request can reach object storage.
        try await record.save(on: database)
        try await storage.upload(data: data, key: reference.key, contentType: purpose.contentType)
        let retained = try await storage.download(key: reference.key, maximumBytes: reference.byteCount)
        guard retained.count == reference.byteCount, Self.digest(retained) == reference.digest else {
            throw ServerError.conflict("Stored artifact does not match the submitted bytes")
        }
        guard let sql = database as? any SQLDatabase else { throw Failure.unsupportedDatabase }
        let ready = try await sql.raw("""
            UPDATE stored_artifacts SET state = 'ready'
            WHERE id = \(bind: reference.id) AND state = 'staging' RETURNING id
            """)
            .first()
        guard ready != nil else { throw ServerError.conflict("Artifact staging has expired") }
        return reference
    }

    /// Must commit on the same handle as the referencing record and its audit event.
    func retain(_ reference: ArtifactReference, on transaction: any Database, now: Date = Date()) async throws {
        guard transaction.inTransaction else { throw Failure.transactionRequired }
        guard let sql = transaction as? any SQLDatabase else { throw Failure.unsupportedDatabase }
        let retained = try await sql.raw("""
            UPDATE stored_artifacts SET state = 'retained', cleanup_after = NULL
            WHERE id = \(bind: reference.id) AND owner_id = \(bind: reference.ownerID)
              AND purpose = \(bind: reference.purpose.rawValue) AND digest = \(bind: reference.digest)
              AND byte_count = \(bind: reference.byteCount) AND state = 'ready' AND expires_at > \(bind: now)
            RETURNING id
            """)
            .first()
        guard retained != nil else { throw ServerError.conflict("Artifact is not available for acceptance") }
    }

    /// Call only after domain authorization and the corresponding disclosure audit gate.
    func download(id: UUID, ownerID: UUID, purpose: ArtifactReference.Purpose, expected: (key: String, digest: String)) async throws -> Data {
        guard let record = try await StoredArtifact.find(id, on: database), record.state == .retained,
              record.ownerID == ownerID, record.purpose == purpose, record.digest == expected.digest,
              (1...purpose.maximumBytes).contains(record.byteCount) else {
            throw ServerError.internalServerError("Accepted artifact metadata is unavailable")
        }
        let reference = try record.reference()
        guard reference.key == expected.key else { throw ServerError.internalServerError("Accepted artifact locator does not match") }
        let bytes = try await storage.download(key: reference.key, maximumBytes: reference.byteCount)
        guard bytes.count == reference.byteCount, Self.digest(bytes) == reference.digest else {
            throw ServerError.internalServerError("Accepted artifact integrity check failed")
        }
        return bytes
    }
}
