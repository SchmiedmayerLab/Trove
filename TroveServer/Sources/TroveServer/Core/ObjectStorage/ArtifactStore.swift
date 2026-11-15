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
import OpenAPIRuntime
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

    private static func byteCount(of body: HTTPBody, maximumBytes: Int) throws -> Int {
        guard case .known(let length) = body.length, let count = Int(exactly: length), (1...maximumBytes).contains(count) else {
            throw ServerError.badRequest("Artifact exceeds the supported size limit")
        }
        return count
    }

    func stage(
        _ data: Data, purpose: ArtifactReference.Purpose, ownerID: UUID, scope: StudyArtifactScope, now: Date = Date()
    ) async throws -> ArtifactReference {
        guard !database.inTransaction else { throw Failure.operationInsideTransaction }
        guard !data.isEmpty, data.count <= purpose.maximumBytes else {
            throw ServerError.badRequest("Artifact exceeds the supported size limit")
        }
        return try await stage(HTTPBody(data), digest: Self.digest(data), purpose: purpose, ownerID: ownerID, scope: scope, now: now)
    }

    func stage(
        _ body: HTTPBody, digest: String, purpose: ArtifactReference.Purpose, ownerID: UUID, scope: StudyArtifactScope, now: Date = Date()
    ) async throws -> ArtifactReference {
        guard purpose != .recording else { throw ServerError.badRequest("Recordings require participant source ownership") }
        let reference = ArtifactReference(
            id: UUID(),
            ownerID: ownerID,
            purpose: purpose,
            digest: digest,
            byteCount: try Self.byteCount(of: body, maximumBytes: purpose.maximumBytes),
            scope: .study(scope)
        )
        return try await stage(body, reference: reference, now: now)
    }

    /// Stores transport bytes only. A ready object is not an accepted clinical record or a study disclosure grant.
    func stageRecording(
        _ body: HTTPBody, digest: String, scope: ParticipantArtifactScope, maximumBytes: Int, now: Date = Date()
    ) async throws -> ArtifactReference {
        guard (1...ArtifactReference.Purpose.recording.maximumBytes).contains(maximumBytes) else {
            throw ServerError.badRequest("Unsupported recording artifact limit")
        }
        let reference = ArtifactReference(
            id: UUID(),
            ownerID: scope.participantID,
            purpose: .recording,
            digest: digest,
            byteCount: try Self.byteCount(of: body, maximumBytes: maximumBytes),
            scope: .participantSource(scope)
        )
        return try await stage(body, reference: reference, now: now)
    }

    private func stage(_ body: HTTPBody, reference: ArtifactReference, now: Date) async throws -> ArtifactReference {
        guard !database.inTransaction else { throw Failure.operationInsideTransaction }
        let digest = reference.digest
        guard digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ServerError.badRequest("Artifact requires a lowercase SHA-256 digest")
        }
        try Task.checkCancellation()
        let record = StoredArtifact(reference: reference, expiresAt: now.addingTimeInterval(3600))
        // Commit the recovery locator before any request can reach object storage.
        try await record.save(on: database)
        return try await uploadReserved(body, reference: reference)
    }

    /// The recording transfer transaction commits this exact recovery row before streaming begins.
    func uploadReservedRecording(_ body: HTTPBody, reference: ArtifactReference) async throws {
        guard !database.inTransaction else { throw Failure.operationInsideTransaction }
        guard reference.purpose == .recording,
              try Self.byteCount(of: body, maximumBytes: reference.byteCount) == reference.byteCount,
              let record = try await StoredArtifact.find(reference.id, on: database), record.state == .staging,
              record.expiresAt > Date(), record.ownerID == reference.ownerID, record.digest == reference.digest,
              record.byteCount == reference.byteCount, try record.reference().scope == reference.scope else {
            throw ServerError.conflict("Recording upload reservation is unavailable")
        }
        _ = try await uploadReserved(body, reference: reference)
    }

    private func uploadReserved(_ body: HTTPBody, reference: ArtifactReference) async throws -> ArtifactReference {
        try Task.checkCancellation()
        let bounded = try BoundedObjectStorageBody.wrap(body, maximumBytes: reference.byteCount)
        try await storage.upload(body: bounded, key: reference.key, contentType: reference.purpose.contentType)
        try await storage.verify(key: reference.key, byteCount: reference.byteCount, digest: reference.digest)
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
              AND byte_count = \(bind: reference.byteCount) AND \(reference.scope.matchingColumns) AND state = 'ready' AND expires_at > \(bind: now)
            RETURNING id
            """)
            .first()
        guard retained != nil else { throw ServerError.conflict("Artifact is not available for acceptance") }
    }

    /// Call only after domain authorization and the corresponding disclosure audit gate.
    func download(id: UUID, ownerID: UUID, purpose: ArtifactReference.Purpose, expected: (key: String, digest: String)) async throws -> Data {
        guard purpose != .recording else { throw ServerError.badRequest("Recording artifacts require authorized file transfer") }
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
