//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import Grove
import OpenAPIRuntime
import SQLKit


/// Authorizes before consuming a body and again before issuing a durable transport receipt.
final class RecordingTransferService: Module, Sendable {
    struct Limits: Sendable {
        static let standard = Self()

        let storedBytes: Int
        let sourceBytes: Int
        let leaseDuration: TimeInterval

        private init() {
            storedBytes = 128 * 1024 * 1024
            sourceBytes = 512 * 1024 * 1024
            leaseDuration = 900
        }

        init(storedBytes: Int, sourceBytes: Int, leaseDuration: TimeInterval = 900) throws {
            guard (1...Int(Int32.max)).contains(storedBytes), (1...Int(Int32.max)).contains(sourceBytes),
                  leaseDuration.isFinite, (1...3600).contains(leaseDuration) else {
                throw ServerError.badRequest("Invalid recording transfer limits")
            }
            self.storedBytes = storedBytes
            self.sourceBytes = sourceBytes
            self.leaseDuration = leaseDuration
        }
    }

    struct Attempt: Sendable {
        let declarationID: UUID
        let reference: ArtifactReference
    }

    enum Reservation: Sendable {
        case upload(Attempt)
        case receipt(RecordingTransferReceipt)
    }

    struct Authorization: Sendable {
        let sourceID: UUID
        let installation: SourceInstallationProof
        let context: AuthContext
    }

    let database: any Database
    let storage: ObjectStorageService
    let limits: Limits

    init(database: any Database, storage: ObjectStorageService, limits: Limits) {
        self.database = database
        self.storage = storage
        self.limits = limits
    }

    func upload(
        _ body: HTTPBody,
        sourceID: UUID,
        transferID: UUID,
        declaration: RecordingTransferDeclaration,
        installation: SourceInstallationProof
    ) async throws -> RecordingTransferReceipt {
        _ = try AuthContext.checkIsParticipant()
        guard case .known(let count) = body.length, count == Int64(declaration.content.storedByteCount) else {
            throw ServerError.badRequest("Recording transfer requires its exact declared body length")
        }
        let reservation = try await reserve(sourceID: sourceID, transferID: transferID, declaration: declaration, installation: installation)
        switch reservation {
        case .receipt:
            break // Lost-response retry: no body consumption or additional object upload.
        case .upload(let attempt):
            do {
                try await ArtifactStore(database: database, storage: storage).uploadReservedRecording(body, reference: attempt.reference)
                try await complete(attempt, sourceID: sourceID, transferID: transferID, declaration: declaration, installation: installation)
            } catch {
                // Release a failed attempt for immediate retry. A crash or failed cleanup transaction is bounded by its lease.
                try? await abandon(attempt)
                try Task.checkCancellation()
                if let error = error as? ServerError { throw error }
                throw ServerError(status: .serviceUnavailable, title: "Upload Interrupted", detail: "Retry the unchanged recording transfer")
            }
        }
        return try await lookup(sourceID: sourceID, transferID: transferID)
    }

    func reserve(
        sourceID: UUID,
        transferID: UUID,
        declaration: RecordingTransferDeclaration,
        installation: SourceInstallationProof,
        now: Date = Date()
    ) async throws -> Reservation {
        let context = try AuthContext.checkIsParticipant()
        let authorization = Authorization(sourceID: sourceID, installation: installation, context: context)
        guard declaration.content.storedByteCount <= limits.storedBytes, declaration.content.sourceByteCount <= limits.sourceBytes else {
            throw ServerError(status: .contentTooLarge, title: "Recording Too Large", detail: "Recording exceeds the configured transfer budget")
        }
        return try await database.transaction { transaction in
            let source = try await self.authorize(
                authorization, declaration: declaration, now: now, on: transaction
            )
            guard let sql = transaction as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
            let store = RecordingTransferStore(sql: sql)
            let id = try await store.declarationID(sourceID: sourceID, transferID: transferID, declaration: declaration, now: now)
            if let receipt = try await store.receipt(sourceID: sourceID, transferID: transferID),
               let artifact = try await StoredArtifact.find(receipt.artifactID, on: transaction),
               artifact.state == .retained || (artifact.state == .ready && artifact.expiresAt > now) {
                return .receipt(receipt)
            }
            let previous = try await store.latestAttempt(for: id)
            if let previous, previous.leaseExpiresAt > now,
               let artifact = try await StoredArtifact.find(previous.artifactID, on: transaction), artifact.state != .discarding {
                throw ServerError.conflict("A recording upload attempt is still active")
            }
            let reference = ArtifactReference(
                id: UUID(),
                ownerID: source.participantID,
                purpose: .recording,
                digest: declaration.content.storedSHA256,
                byteCount: declaration.content.storedByteCount,
                scope: .participantSource(.init(participantID: source.participantID, sourceBindingID: sourceID))
            )
            try await StoredArtifact(reference: reference, expiresAt: now.addingTimeInterval(3600)).save(on: transaction)
            try await store.insertAttempt(
                artifactID: reference.id,
                declarationID: id,
                number: (previous?.number ?? 0) + 1,
                leaseExpiresAt: now.addingTimeInterval(self.limits.leaseDuration)
            )
            return .upload(.init(declarationID: id, reference: reference))
        }
    }

    func complete(
        _ attempt: Attempt,
        sourceID: UUID,
        transferID: UUID,
        declaration: RecordingTransferDeclaration,
        installation: SourceInstallationProof,
        now: Date = Date()
    ) async throws {
        let context = try AuthContext.checkIsParticipant()
        let authorization = Authorization(sourceID: sourceID, installation: installation, context: context)
        try await database.transaction { transaction in
            let source = try await self.authorize(
                authorization, declaration: declaration, now: now, on: transaction
            )
            guard let sql = transaction as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
            let store = RecordingTransferStore(sql: sql)
            let id = try await store.declarationID(sourceID: sourceID, transferID: transferID, declaration: declaration, now: now)
            guard id == attempt.declarationID, attempt.reference.purpose == .recording,
                  attempt.reference.ownerID == source.participantID,
                  attempt.reference.digest == declaration.content.storedSHA256,
                  attempt.reference.byteCount == declaration.content.storedByteCount,
                  attempt.reference.scope == .participantSource(.init(participantID: source.participantID, sourceBindingID: sourceID)),
                  let latest = try await store.latestAttempt(for: id), latest.artifactID == attempt.reference.id,
                  latest.leaseExpiresAt > now else { throw ServerError.conflict("Recording upload attempt has expired or was superseded") }
            if try await store.receipt(sourceID: sourceID, transferID: transferID) != nil {
                return
            }
            // A no-op UPDATE locks the storage row against cleanup until this receipt commits.
            let ready = try await sql.raw("""
                UPDATE stored_artifacts SET state = state
                WHERE id = \(bind: attempt.reference.id) AND state = 'ready' AND expires_at > \(bind: now)
                  AND purpose = 'recording' AND digest = \(bind: declaration.content.storedSHA256)
                  AND byte_count = \(bind: declaration.content.storedByteCount)
                  AND participant_id = \(bind: source.participantID) AND source_binding_id = \(bind: sourceID)
                RETURNING expires_at
                """)
                .first()
            guard let ready else { throw ServerError.conflict("Recording bytes are not verified and available") }
            try await store.insertReceipt(reference: attempt.reference, verifiedAt: now, expiresAt: ready.decode(column: "expires_at", as: Date.self))
            try await AuditRepository.recordMutation(.init(
                context: context.auditContext,
                action: .recordingTransferStored,
                scope: .participantSource(participantID: source.participantID, sourceBindingID: sourceID),
                target: .init(id: attempt.reference.id)
            ), on: transaction)
        }
    }

    func lookup(sourceID: UUID, transferID: UUID) async throws -> RecordingTransferReceipt {
        let context = try AuthContext.checkIsParticipant()
        // Owned receipts remain recoverable after withdrawal/revocation; this admits no new bytes.
        let source = try await SourceBindingService(database: database).find(id: sourceID)
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        guard let receipt = try await RecordingTransferStore(sql: sql).receipt(sourceID: sourceID, transferID: transferID) else {
            throw ServerError.notFound("Recording transfer receipt not found")
        }
        return try await AuditRepository.disclose(.init(
            context: context.auditContext,
            action: .recordingTransferReceiptDisclosure,
            scope: .participantSource(participantID: source.participantID, sourceBindingID: sourceID),
            target: .init(id: receipt.artifactID)
        ), on: database) { _ in receipt }
    }

    func authorize(
        _ authorization: Authorization, declaration: RecordingTransferDeclaration, now: Date, on transaction: any Database
    ) async throws -> SourceBinding {
        let source = try await ClinicalEventStore(database: transaction).lockSourceOwner(
            sourceID: authorization.sourceID, context: authorization.context, on: transaction
        )
        _ = try await authorization.installation.validate(source: source, on: transaction)
        _ = try await ClinicalGrantStore(database: transaction, source: source, context: authorization.context, acceptedAt: now).authorities(
            outputs: [declaration.output], intent: declaration.intent, requireCustodyCoverage: true
        )
        return source
    }
}
