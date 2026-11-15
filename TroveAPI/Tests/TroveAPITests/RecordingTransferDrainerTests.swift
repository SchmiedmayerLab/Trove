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


struct RecordingTransferDrainerTests {
    private actor Session {
        var valid = true
        func end() { valid = false }
        func check() throws {
            if !valid { throw CancellationError() }
        }
    }

    @Test(arguments: [false, true])
    func lostResponseRecoversAcrossRestartWithoutDuplicatingUploads(registration: Bool) async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let transfer = try await Self.prepare(journal)
            let peer = RecordingTransferTransport(transfer)
            await peer.configure(registration ? .loseRegistration : .loseUpload)
            let drainer = try Self.drainer(journal, peer: peer)
            await #expect(throws: RecordingTransferDrainer.Failure.transportFailed) { try await drainer.transfer(transfer.transferID) }
            #expect(try await journal.recordingTransfer(for: transfer.transferID)?.receipt == nil)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let recovered = try await Self.drainer(reopened, peer: peer).transfer(transfer.transferID)
            try transfer.commitment.verify(recovered, sourceID: transfer.sourceID, transferID: transfer.transferID)
            #expect(await peer.uploadByteCounts == [Int(transfer.commitment.declaration.content.storedByteCount)])
            #expect(try await reopened.reclaimRecordingFiles() == 0)
            let calls = await peer.operations
            #expect(try await Self.drainer(reopened, peer: peer).transfer(transfer.transferID) == recovered)
            #expect(await peer.operations == calls)
            await reopened.close()
        }
    }

    @Test(arguments: [false, true])
    func wrongAcknowledgementDoesNotCommitLocalCustody(registration: Bool) async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let transfer = try await Self.prepare(journal)
            let peer = RecordingTransferTransport(transfer)
            await peer.configure(registration ? .mismatchedRegistration : .mismatchedReceipt)
            let drainer = try Self.drainer(journal, peer: peer)
            await #expect(throws: RecordingTransferDrainer.Failure.invalidReceipt) { try await drainer.transfer(transfer.transferID) }
            #expect(try await journal.recordingTransfer(for: transfer.transferID)?.receipt == nil)
            #expect(try await journal.reclaimRecordingFiles() == 0)
            #expect(await peer.uploadByteCounts.count == (registration ? 0 : 1))
        }
    }

    @Test
    func changedQueuedBytesCannotReachTheUploadEndpoint() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let transfer = try await Self.prepare(journal)
            let url = try await journal.recordingURL(for: transfer.transferID)
            let handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: Data([0]))
            try handle.close()
            let peer = RecordingTransferTransport(transfer)
            let drainer = try Self.drainer(journal, peer: peer)
            await #expect(throws: RecordingTransferDrainer.Failure.fileChanged) { try await drainer.transfer(transfer.transferID) }
            #expect(await peer.operations == [Operations.LookupParticipantRecordingTransferReceipt.id])
            #expect(try await journal.recordingTransfer(for: transfer.transferID)?.receipt == nil)
        }
    }

    @Test
    func sessionLossStopsTheInstanceBeforeRegistration() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let transfer = try await Self.prepare(journal), session = Session()
            let peer = RecordingTransferTransport(transfer)
            await peer.afterReply { await session.end() }
            let client = Client(serverURL: try #require(URL(string: DeliveryFixture.scope.backend)), configuration: .trove, transport: peer)
            let drainer = try RecordingTransferDrainer(journal: journal, scope: DeliveryFixture.scope, client: client) { try await session.check() }
            for _ in 0..<2 {
                await #expect(throws: RecordingTransferDrainer.Failure.authenticationRequired) { try await drainer.transfer(transfer.transferID) }
            }
            #expect(await peer.operations == [Operations.LookupParticipantRecordingTransferReceipt.id])
            #expect(await peer.uploadByteCounts.isEmpty)
        }
    }

    @Test
    func cancelledBodyRetainsTheDeclarationAndFileForRetry() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let transfer = try await Self.prepare(journal)
            let peer = RecordingTransferTransport(transfer)
            await peer.duringUpload { withUnsafeCurrentTask { $0?.cancel() } }
            let drainer = try Self.drainer(journal, peer: peer)
            let task = Task { try await drainer.transfer(transfer.transferID) }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await journal.recordingTransfer(for: transfer.transferID)?.registration != nil)
            #expect(try await journal.recordingTransfer(for: transfer.transferID)?.receipt == nil)
            #expect(try await journal.reclaimRecordingFiles() == 0)
        }
    }
}


extension RecordingTransferDrainerTests {
    private static func prepare(_ journal: EventDeliveryJournal) async throws -> DeliveryRecordingTransfer {
        let (payload, declaration) = try RecordingDeliveryFixture.make()
        let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
        let ids = try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: [payload])
        let id = try #require(ids.first)
        let file = try #require(await journal.recordingReferences(for: id).first)
        return try await journal.prepareRecordingTransfer(recordingID: file.id, deliveryID: id, declaration: declaration)
    }

    private static func drainer(_ journal: EventDeliveryJournal, peer: RecordingTransferTransport) throws -> RecordingTransferDrainer {
        let client = Client(serverURL: try #require(URL(string: DeliveryFixture.scope.backend)), configuration: .trove, transport: peer)
        return try .init(journal: journal, scope: DeliveryFixture.scope, client: client, validateSession: {}, now: { RecordingDeliveryFixture.start })
    }
}
