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


struct RecordingAcquisitionCommitTests {
    @Test
    func checkpointAndDeclarationSurviveRestartAndDeliveredReplayTogether() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let (payload, declaration) = try RecordingDeliveryFixture.make()
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let ids = try await journal.stage(
                from: checkpoint, nextCursor: Data([1]), payloads: [payload], recordingDeclarations: [[declaration]]
            )
            let id = try #require(ids.first)
            let file = try #require(await journal.recordingReferences(for: id).first)
            #expect(try await journal.recordingTransfer(for: file.id)?.commitment.declaration == declaration)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let retained = try #require(await reopened.recordingTransfer(for: file.id))
            #expect(retained.commitment.declaration == declaration)
            #expect(try await reopened.checkpoint(for: DeliveryFixture.sourceID).cursor == Data([1]))
            let attempt = try #require(await reopened.prepareAttempt(id))
            try await reopened.recordReceipt(DeliveryFixture.receipt(attempt), for: id)
            #expect(try await reopened.reclaimRecordingFiles() == 1)
            let next = try await reopened.checkpoint(for: DeliveryFixture.sourceID)
            #expect(try await reopened.stage(
                from: next, nextCursor: Data([2]), payloads: [payload], recordingDeclarations: [[declaration]]
            ) == ids)
            #expect(try await reopened.recordingReferences(for: id) == [file])
            #expect(try await reopened.recordingTransfer(for: file.id)?.commitment.serialized == retained.commitment.serialized)
            #expect(try await reopened.status(for: id) == .delivered)
            await reopened.close()
        }
    }

    @Test(arguments: ["missing", "digest", "targets"])
    func invalidDeclarationCannotCommitAnyPayloadOrAdvanceTheCursor(field: String) async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let (payload, original) = try RecordingDeliveryFixture.make()
            var declaration = original
            if field == "digest" {
                declaration.content.storedSHA256 = String(repeating: "0", count: 64)
                declaration.content.sourceSHA256 = declaration.content.storedSHA256
            }
            if field == "targets" { declaration.targets[0].consentId = UUID().uuidString }
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let ordinary = try DeliveryFixture.payload(sequence: 1, changes: ["ordinary"])
            await #expect(throws: DeliveryJournalError.eventIdentityMismatch) {
                try await journal.stage(
                    from: checkpoint,
                    nextCursor: Data([1]),
                    payloads: [ordinary, payload],
                    recordingDeclarations: [[], field == "missing" ? [] : [declaration]]
                )
            }
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            #expect(try await reopened.pendingDeliveryIDs().isEmpty)
            #expect(try await reopened.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
            let ids = try await reopened.stage(
                from: checkpoint, nextCursor: Data([1]), payloads: [ordinary, payload], recordingDeclarations: [[], [original]]
            )
            #expect(ids.count == 2)
            let file = try #require(await reopened.recordingReferences(for: ids[1]).first)
            #expect(try await reopened.recordingTransfer(for: file.id)?.commitment.declaration == original)
            await reopened.close()
        }
    }
}
