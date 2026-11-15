//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import TroveAPIClient


struct DeliveryRecordingTransferTests {
    @Test
    func transferEvidenceSurvivesRestartButOnlyClinicalCustodyRetiresFiles() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let (payload, declaration) = try RecordingDeliveryFixture.make()
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let ids = try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: [payload])
            let id = try #require(ids.first)
            let attempt = try #require(await journal.prepareAttempt(id))
            let file = try #require(attempt.recordings.first)
            let transfer = try await journal.prepareRecordingTransfer(recordingID: file.id, deliveryID: id, declaration: declaration)
            try await Self.verifyImmutableDeclaration(journal, fileID: file.id, deliveryID: id, transfer: transfer, declaration: declaration)
            let registration = RecordingDeliveryFixture.registration(transfer)
            let receipt = RecordingDeliveryFixture.receipt(transfer)
            try await journal.recordRecordingRegistration(registration, for: file.id)
            try await journal.recordRecordingReceipt(receipt, for: file.id)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let recovered = try #require(await reopened.recordingTransfer(for: file.id))
            #expect(recovered.commitment.serialized == transfer.commitment.serialized)
            #expect(recovered.registration == registration && recovered.receipt == receipt)
            #expect(recovered.usableReceipt(at: receipt.expiresAt) == nil)
            #expect(recovered.usableReceipt(at: receipt.verifiedAt) == receipt)
            #expect(try await reopened.reclaimRecordingFiles() == 0)
            #expect(try await reopened.status(for: id) == .pending)
            let path = try await reopened.recordingURL(for: file.id)
            #expect(FileManager.default.fileExists(atPath: path.path))
            try await reopened.recordReceipt(DeliveryFixture.receipt(attempt), for: id)
            var lateReceipt = receipt
            lateReceipt.artifactId = UUID().uuidString
            lateReceipt.verifiedAt = receipt.expiresAt
            lateReceipt.expiresAt = receipt.expiresAt.addingTimeInterval(3600)
            await #expect(throws: DeliveryJournalError.receiptConflict) { try await reopened.recordRecordingReceipt(lateReceipt, for: file.id) }
            #expect(try await reopened.reclaimRecordingFiles() == 1)
            #expect(try await reopened.recordingTransfer(for: file.id)?.receipt == receipt)
            #expect(try await reopened.pruneDelivered() == 1)
            #expect(try await reopened.recordingTransfer(for: file.id) == nil)
            await reopened.close()
        }
    }

    @Test(arguments: ["path", "output", "size", "digest", "targets", "period"])
    func declarationMustMatchTheQueuedFileAndExactClinicalOutput(field: String) async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let (payload, original) = try RecordingDeliveryFixture.make()
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let ids = try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: [payload])
            let id = try #require(ids.first)
            let file = try #require(await journal.recordingReferences(for: id).first)
            var declaration = original
            switch field {
            case "path": declaration.attachmentPath = "recordings/other.csv"
            case "output":
                declaration.outputFullUrl = "urn:uuid:other"
                declaration.targets[0].outputFullUrls = [declaration.outputFullUrl]
            case "size":
                declaration.content.storedByteCount += 1
                declaration.content.sourceByteCount += 1
            case "digest":
                declaration.content.storedSHA256 = String(repeating: "0", count: 64)
                declaration.content.sourceSHA256 = declaration.content.storedSHA256
            case "targets": declaration.targets[0].consentId = UUID().uuidString
            default: declaration.effectiveAt.addTimeInterval(-1)
            }
            await #expect(throws: DeliveryJournalError.eventIdentityMismatch) {
                try await journal.prepareRecordingTransfer(recordingID: file.id, deliveryID: id, declaration: declaration)
            }
            #expect(try await journal.recordingTransfer(for: file.id) == nil)
            #expect(try await journal.pendingDeliveryIDs() == ids)
        }
    }

    @Test
    func invalidReceiptsAndUnexpiredReplacementCannotAlterEvidence() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let (payload, declaration) = try RecordingDeliveryFixture.make()
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let ids = try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: [payload])
            let id = try #require(ids.first)
            let file = try #require(await journal.recordingReferences(for: id).first)
            let transfer = try await journal.prepareRecordingTransfer(recordingID: file.id, deliveryID: id, declaration: declaration)
            var invalid = RecordingDeliveryFixture.registration(transfer)
            invalid.declarationSHA256 = String(repeating: "0", count: 64)
            await #expect(throws: RecordingTransferCommitment.Failure.receiptMismatch) {
                try await journal.recordRecordingRegistration(invalid, for: file.id)
            }
            #expect(try await journal.recordingTransfer(for: file.id)?.registration == nil)
            let original = RecordingDeliveryFixture.receipt(transfer)
            try await journal.recordRecordingReceipt(original, for: file.id)
            var replacement = RecordingDeliveryFixture.receipt(transfer)
            await #expect(throws: DeliveryJournalError.receiptConflict) { try await journal.recordRecordingReceipt(replacement, for: file.id) }
            #expect(try await journal.recordingTransfer(for: file.id)?.receipt == original)
            replacement.verifiedAt = original.expiresAt
            replacement.expiresAt = original.expiresAt.addingTimeInterval(3600)
            try await journal.recordRecordingReceipt(replacement, for: file.id)
            #expect(try await journal.recordingTransfer(for: file.id)?.receipt == replacement)
            #expect(try await journal.reclaimRecordingFiles() == 0)
        }
    }

    @Test
    func consistentButForeignDeclarationCannotBeRecoveredFromCorruptedState() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let (payload, declaration) = try RecordingDeliveryFixture.make()
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let ids = try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: [payload])
            let id = try #require(ids.first)
            let file = try #require(await journal.recordingReferences(for: id).first)
            _ = try await journal.prepareRecordingTransfer(recordingID: file.id, deliveryID: id, declaration: declaration)
            var changed = declaration
            changed.targets[0].consentId = UUID().uuidString
            let foreign = try RecordingTransferCommitment(changed)
            let database = try DeliverySQLite(url: url)
            defer { database.close() }
            try database.execute("UPDATE recording_transfer SET declaration = ?, declaration_sha256 = ?", [
                .blob(foreign.serialized), .text(foreign.sha256)
            ])
            await #expect(throws: DeliveryJournalError.eventIdentityMismatch) { try await journal.recordingTransfer(for: file.id) }
            #expect(try await journal.pendingDeliveryIDs() == ids)
            #expect(try await journal.reclaimRecordingFiles() == 0)
        }
    }

    @Test
    func declarationCapacityFailurePreservesTheFileAndDoesNotLeavePartialTransferState() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let (payload, declaration) = try RecordingDeliveryFixture.make()
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let ids = try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: [payload])
            let id = try #require(ids.first)
            let file = try #require(await journal.recordingReferences(for: id).first)
            await journal.close()
            let constrained = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting, limits: .init(maximumBytes: 1))
            await #expect(throws: DeliveryJournalError.capacityExceeded) {
                try await constrained.prepareRecordingTransfer(recordingID: file.id, deliveryID: id, declaration: declaration)
            }
            #expect(try await constrained.recordingTransfer(for: file.id) == nil)
            #expect(try await constrained.pendingDeliveryIDs() == ids)
            let path = try await constrained.recordingURL(for: file.id)
            #expect(FileManager.default.fileExists(atPath: path.path))
            await constrained.close()
        }
    }
}


extension DeliveryRecordingTransferTests {
    private static func verifyImmutableDeclaration(
        _ journal: EventDeliveryJournal,
        fileID: UUID,
        deliveryID: UUID,
        transfer: DeliveryRecordingTransfer,
        declaration: Components.Schemas.RecordingTransferDeclaration
    ) async throws {
        let replay = try await journal.prepareRecordingTransfer(recordingID: fileID, deliveryID: deliveryID, declaration: declaration)
        #expect(replay.transferID == transfer.transferID && replay.commitment.serialized == transfer.commitment.serialized)
        var changed = declaration
        changed.content.encoding = .zstd
        changed.content.sourceSHA256 = String(repeating: "0", count: 64)
        await #expect(throws: DeliveryJournalError.eventIdentityMismatch) {
            try await journal.prepareRecordingTransfer(recordingID: fileID, deliveryID: deliveryID, declaration: changed)
        }
    }
}
