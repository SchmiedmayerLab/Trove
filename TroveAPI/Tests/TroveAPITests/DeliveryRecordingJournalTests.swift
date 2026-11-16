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


/// Queue durability is independent of clinical attachment admission, which is enforced by the receiver.
struct DeliveryRecordingJournalTests {
    private enum InputFailure: Error { case interrupted }

    @Test
    func filesAndCursorSurviveReopeningAndOnlyCustodyPermitsRetirement() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let payload = try Self.payload(Data([1, 2, 3]))
            let ids = try await journal.stage(from: checkpoint, nextCursor: Data([7]), payloads: [payload])
            let id = try #require(ids.first)
            let first = try #require(await journal.prepareAttempt(id))
            let file = try #require(first.recordings.first)
            let path = try await journal.recordingURL(for: file.id)
            #expect(try Data(contentsOf: path) == Data([1, 2, 3]))
            #expect(try await journal.reclaimRecordingFiles() == 0)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let attempt = try #require(await reopened.prepareAttempt(id))
            #expect(attempt.recordings == first.recordings && attempt.custodyWasUncertain)
            #expect(try await reopened.checkpoint(for: DeliveryFixture.sourceID).cursor == Data([7]))
            var invalid = DeliveryFixture.receipt(attempt)
            invalid.payloadSHA256 = String(repeating: "0", count: 64)
            await #expect(throws: (any Error).self) { try await reopened.recordReceipt(invalid, for: id) }
            #expect(try Data(contentsOf: path) == Data([1, 2, 3]))
            try await reopened.recordReceipt(DeliveryFixture.receipt(attempt), for: id)
            #expect(try await reopened.pruneDelivered() == 0)
            #expect(try await reopened.reclaimRecordingFiles() == 1)
            #expect(!FileManager.default.fileExists(atPath: path.path))
            #expect(try await reopened.recordingReferences(for: id) == first.recordings)
            #expect(try await reopened.pruneDelivered() == 1)
            await reopened.close()
        }
    }

    @Test
    func reservationCommitsBeforeBytesAndInterruptedStagingDoesNotAdvanceTheCursor() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let base = try DeliveryFixture.payload(sequence: 1, changes: ["recording"])
            let recording = DeliveryRecording(relativePath: "recordings/route.csv", byteCount: 3) { consume in
                let independent = try DeliverySQLite(url: url)
                defer { independent.close() }
                let rows = try independent.query("SELECT state FROM recording_file") { try DeliverySQLite.text($0, 0) }
                #expect(rows == ["reserved"])
                // A recovery writer cannot remove this reservation while staging holds the writer lock.
                #expect(throws: DeliverySQLite.Failure.self) { try independent.transaction {} }
                try consume(Data([1]))
                throw InputFailure.interrupted
            }
            await #expect(throws: InputFailure.self) {
                try await journal.stage(from: checkpoint, nextCursor: Data([8]), payloads: [
                    .init(bytes: base.bytes, targets: base.targets, recordings: [recording])
                ])
            }
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            #expect(try await reopened.reclaimRecordingFiles() == 1)
            #expect(try await reopened.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
            let ids = try await reopened.stage(from: checkpoint, nextCursor: Data([8]), payloads: [Self.payload(Data([1, 2, 3]))])
            #expect(ids.count == 1)
            await reopened.close()
        }
    }

    @Test
    func exactReplayRetainsFileIdentityAndChangedBytesRollBack() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let payload = try Self.payload(Data([1, 2, 3]))
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let first = try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: [payload])
            let id = try #require(first.first)
            let references = try await journal.recordingReferences(for: id)
            let replayCheckpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            #expect(try await journal.stage(from: replayCheckpoint, nextCursor: Data([2]), payloads: [payload]) == first)
            #expect(try await journal.recordingReferences(for: id) == references)
            #expect(try await journal.reclaimRecordingFiles() == 1)
            let current = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let changed = EventDeliveryJournal.Payload(bytes: payload.bytes, targets: payload.targets, recordings: [Self.recording(Data([1, 2, 4]))])
            await #expect(throws: DeliveryJournalError.eventIdentityMismatch) {
                try await journal.stage(from: current, nextCursor: Data([3]), payloads: [changed])
            }
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID) == current)
            #expect(try await journal.reclaimRecordingFiles() == 1)
            #expect(try await journal.recordingReferences(for: id) == references)
            let file = try #require(references.first)
            #expect(try Data(contentsOf: await journal.recordingURL(for: file.id)) == Data([1, 2, 3]))
        }
    }

    @Test
    func recordingCapacityFailurePreservesEarlierFilesAndCheckpoint() async throws {
        try await DeliveryFixture.withJournal(limits: .init(maximumRecordingBytes: 4, maximumPendingRecordingBytes: 6)) { journal, _ in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let ids = try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: [Self.payload(Data([1, 2, 3, 4]))])
            let current = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            await #expect(throws: DeliveryJournalError.capacityExceeded) {
                try await journal.stage(from: current, nextCursor: Data([2]), payloads: [Self.payload(Data([5, 6, 7, 8]))])
            }
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID) == current)
            #expect(try await journal.pendingDeliveryIDs() == ids)
            #expect(try await journal.reclaimRecordingFiles() == 0)
        }
    }

    @Test(arguments: ["", "/route.csv", "../route.csv", "route//data.csv", "route/./data.csv", "route%2Fdata.csv", "route.csv?token=x"])
    func invalidAttachmentPathsDoNotCreateReservations(path: String) async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let base = try Self.payload(Data([1]))
            let recording = DeliveryRecording(relativePath: path, byteCount: 1) { try $0(Data([1])) }
            await #expect(throws: DeliveryJournalError.invalidConfiguration) {
                try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: [
                    .init(bytes: base.bytes, targets: base.targets, recordings: [recording])
                ])
            }
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
            #expect(try FileManager.default.contentsOfDirectory(atPath: url.appendingPathExtension("recordings").path).isEmpty)
        }
    }

    @Test
    func laterPayloadFailureRollsBackTheWholeDeltaAndLeavesBothFilesRecoverable() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let first = try Self.payload(Data([1, 2, 3]))
            let base = try DeliveryFixture.payload(sequence: 2, changes: ["another-recording"])
            let interrupted = DeliveryRecording(relativePath: "recordings/another.csv", byteCount: 3) { consume in
                try consume(Data([4]))
                throw InputFailure.interrupted
            }
            await #expect(throws: InputFailure.self) {
                try await journal.stage(from: checkpoint, nextCursor: Data([9]), payloads: [
                    first, .init(bytes: base.bytes, targets: base.targets, recordings: [interrupted])
                ])
            }
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
            let files = try FileManager.default.contentsOfDirectory(at: url.appendingPathExtension("recordings"), includingPropertiesForKeys: nil)
            #expect(try files.map { try Data(contentsOf: $0).count }.sorted() == [1, 3])
            #expect(try await journal.reclaimRecordingFiles() == 2)
        }
    }
}


extension DeliveryRecordingJournalTests {
    private static func recording(_ bytes: Data) -> DeliveryRecording {
        .init(relativePath: "recordings/route.csv", byteCount: bytes.count) { try $0(bytes) }
    }

    private static func payload(_ bytes: Data) throws -> EventDeliveryJournal.Payload {
        let base = try DeliveryFixture.payload(sequence: 1, changes: ["recording"])
        return .init(bytes: base.bytes, targets: base.targets, recordings: [recording(bytes)])
    }
}
