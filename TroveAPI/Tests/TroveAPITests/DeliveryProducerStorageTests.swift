//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import Testing
@testable import TroveAPIClient


struct DeliveryProducerStorageTests {
    private enum Failure: Error { case interrupted }

    @Test
    func writerContentionFailsWithoutChangingTheLedgerAndCanRetry() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let storage = try await journal.producerStorage(from: checkpoint)
            try storage.transaction { try $0.write(Data([1]), for: "reservation") }
            let writer = try DeliverySQLite(url: url)
            defer { writer.close() }
            try writer.transaction {
                #expect(throws: DeliverySQLite.Failure.self) {
                    try storage.transaction { try $0.write(Data([2]), for: "reservation") }
                }
            }
            #expect(try storage.transaction { try $0.read("reservation") } == Data([1]))
            try storage.transaction { try $0.write(Data([2]), for: "reservation") }
            #expect(try storage.transaction { try $0.read("reservation") } == Data([2]))
        }
    }

    @Test
    func stagingAtomicallyRetiresLedgerAndRejectsStaleHandlesAfterRestart() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let storage = try await journal.producerStorage(from: journal.checkpoint(for: DeliveryFixture.sourceID))
            try storage.transaction { try $0.write(Data([1]), for: "reservation") }
            await #expect(throws: EventSubmissionCommitment.ValidationError.invalidEnvelope) {
                try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: [.init(bytes: Data(), targets: [])])
            }
            #expect(try storage.transaction { try $0.read("reservation") } == Data([1]))
            let ids = try await journal.stage(
                from: checkpoint, nextCursor: Data([1]), payloads: [DeliveryFixture.payload(sequence: 1, changes: ["sample"])]
            )
            await #expect(throws: DeliveryJournalError.staleCheckpoint) {
                _ = try await journal.producerStorage(from: checkpoint)
            }
            // Simulate termination before the exporter can release its in-memory receipt.
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let next = try await reopened.producerStorage(from: reopened.checkpoint(for: DeliveryFixture.sourceID))
            #expect(try next.transaction { try $0.keys(prefixedBy: "") }.isEmpty)
            try next.transaction { try $0.write(Data([2]), for: "reservation") }
            #expect(throws: DeliveryJournalError.staleCheckpoint) {
                try storage.transaction { try $0.remove("reservation") }
            }
            #expect(try next.transaction { try $0.read("reservation") } == Data([2]))
            #expect(try await reopened.checkpoint(for: DeliveryFixture.sourceID).cursor == Data([1]))
            #expect(try await reopened.pendingDeliveryIDs() == ids)
            await reopened.close()
        }
    }

    @Test
    func permanentRevocationRetiresOnlyThatSourcesDeletionBounds() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let otherID = UUID()
            try await DeliveryFixture.register(journal, sourceID: otherID, query: Data([1]))
            for id in [DeliveryFixture.sourceID, otherID] {
                let checkpoint = try await journal.checkpoint(for: id)
                _ = try await journal.deletionDetections(for: [UUID()], from: checkpoint, at: .now)
            }
            let setup = try await journal.sourceSetup(for: DeliveryFixture.epoch)
            var binding = try #require(setup.binding)
            binding.revokedAt = binding.createdAt
            try await journal.confirmSource(binding, for: setup)
            let connection = try DeliverySQLite(url: url)
            defer { connection.close() }
            let sources = try connection.query("SELECT source_id FROM deletion_detection") { try DeliverySQLite.text($0, 0) }
            #expect(sources == [otherID.uuidString.lowercased()])
        }
    }

    @Test
    func transactionsRollbackAndReopenWithoutChangingBytes() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let storage = try await journal.producerStorage(from: journal.checkpoint(for: DeliveryFixture.sourceID))
            let bytes = Data("{\"value\":1.00}".utf8)
            try storage.transaction { transaction in
                try transaction.write(bytes, for: "entry:a")
                #expect(try transaction.read("entry:a") == bytes)
                #expect(try transaction.keys(prefixedBy: "entry:") == ["entry:a"])
            }
            #expect(throws: Failure.self) {
                try storage.transaction { transaction in
                    try transaction.remove("entry:a")
                    try transaction.write(Data([7]), for: "entry:b")
                    throw Failure.interrupted
                }
            }
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let restored = try await reopened.producerStorage(from: reopened.checkpoint(for: DeliveryFixture.sourceID))
            try restored.transaction { transaction throws in
                #expect(try transaction.keys(prefixedBy: "") == ["entry:a"])
                #expect(try transaction.read("entry:a") == bytes)
                #expect(try transaction.read("entry:b") == nil)
            }
            await reopened.close()
        }
    }

    @Test
    func oneSourceCannotReadAnotherSourcesLedger() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let first = try await journal.producerStorage(from: journal.checkpoint(for: DeliveryFixture.sourceID))
            let otherID = UUID()
            try await DeliveryFixture.register(journal, sourceID: otherID, query: Data([1]))
            let other = try await journal.producerStorage(from: journal.checkpoint(for: otherID))
            try first.transaction { try $0.write(Data([1]), for: "entry") }
            try other.transaction { transaction in
                #expect(try transaction.read("entry") == nil)
                try transaction.write(Data([2]), for: "entry")
            }
            #expect(try first.transaction { try $0.read("entry") } == Data([1]))
        }
    }

    @Test
    func escapedTransactionCannotAlterTheLedger() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let storage = try await journal.producerStorage(from: journal.checkpoint(for: DeliveryFixture.sourceID))
            let escaped = try storage.transaction { $0 }
            #expect(throws: DeliveryJournalError.invalidConfiguration) { try escaped.write(Data([1]), for: "entry") }
            #expect(try storage.transaction { try $0.read("entry") } == nil)
        }
    }

    @Test
    func revocationInvalidatesAlreadyObtainedStorage() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let storage = try await journal.producerStorage(from: journal.checkpoint(for: DeliveryFixture.sourceID))
            let setup = try await journal.sourceSetup(for: DeliveryFixture.epoch)
            var binding = try #require(setup.binding)
            binding.revokedAt = binding.createdAt
            try await journal.confirmSource(binding, for: setup)
            #expect(throws: DeliveryJournalError.sourceRevoked) {
                try storage.transaction { try $0.write(Data([1]), for: "entry") }
            }
        }
    }

    @Test
    func detectionTimeSurvivesFailureAndRestartUntilAtomicStaging() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let record = UUID()
            let instant = Date(timeIntervalSince1970: 1_800_000_000)
            let first = try await journal.deletionDetections(for: [record], from: checkpoint, at: instant)
            await #expect(throws: EventSubmissionCommitment.ValidationError.invalidEnvelope) {
                try await journal.stage(
                    from: checkpoint,
                    nextCursor: Data([1]),
                    payloads: [.init(bytes: Data(), targets: [])],
                    observedDeletions: [record]
                )
            }
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let retry = try await reopened.deletionDetections(for: [record], from: checkpoint, at: instant.addingTimeInterval(3600))
            #expect(first == retry && retry[record] == instant)
            let payload = DeliveryFixture.payload(sequence: 1, changes: ["retraction"])
            _ = try await reopened.stage(from: checkpoint, nextCursor: Data([1]), payloads: [payload], observedDeletions: [record])
            let connection = try DeliverySQLite(url: url)
            #expect(try connection.query("SELECT record_id FROM deletion_detection") { try DeliverySQLite.text($0, 0) }.isEmpty)
            connection.close()
            await reopened.close()
        }
    }
}
