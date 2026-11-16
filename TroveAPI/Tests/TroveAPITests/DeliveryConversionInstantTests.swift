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


struct DeliveryConversionInstantTests {
    @Test
    func instantSurvivesFailureAndRestartUntilAtomicStaging() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let instant = Date(timeIntervalSince1970: 1_800_000_000)
            #expect(try await journal.conversionInstant(from: checkpoint, at: instant) == instant)
            await #expect(throws: EventSubmissionCommitment.ValidationError.invalidEnvelope) {
                try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: [.init(bytes: Data(), targets: [])])
            }
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            #expect(try await reopened.conversionInstant(from: checkpoint, at: instant.addingTimeInterval(60)) == instant)
            let payload = try DeliveryFixture.payload(sequence: 1, changes: ["sample"])
            let ids = try await reopened.stage(from: checkpoint, nextCursor: Data([1]), payloads: [payload])
            await #expect(throws: DeliveryJournalError.staleCheckpoint) {
                try await reopened.conversionInstant(from: checkpoint, at: instant)
            }
            let next = try await reopened.checkpoint(for: DeliveryFixture.sourceID)
            #expect(try await reopened.conversionInstant(from: next, at: instant.addingTimeInterval(60)) == instant.addingTimeInterval(60))
            #expect(try await reopened.pendingDeliveryIDs() == ids)
            await reopened.close()
        }
    }

    @Test
    func separateSourcesKeepSeparateConversionTimes() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let first = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let otherID = UUID()
            try await DeliveryFixture.register(journal, sourceID: otherID, query: Data([1]))
            let other = try await journal.checkpoint(for: otherID)
            let instant = Date(timeIntervalSince1970: 1_800_000_000)
            #expect(try await journal.conversionInstant(from: first, at: instant) == instant)
            #expect(try await journal.conversionInstant(from: other, at: instant.addingTimeInterval(1)) == instant.addingTimeInterval(1))
            #expect(try await journal.conversionInstant(from: first, at: instant.addingTimeInterval(2)) == instant)
        }
    }

    @Test
    func revocationInvalidatesAnExistingCheckpoint() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            _ = try await journal.conversionInstant(from: checkpoint)
            let setup = try await journal.sourceSetup(for: DeliveryFixture.epoch)
            var binding = try #require(setup.binding)
            binding.revokedAt = binding.createdAt
            try await journal.confirmSource(binding, for: setup)
            await #expect(throws: DeliveryJournalError.sourceRevoked) {
                try await journal.conversionInstant(from: checkpoint)
            }
        }
    }

    @Test
    func writerContentionCannotLeaveAPartialInstant() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let writer = try DeliverySQLite(url: url)
            defer { writer.close() }
            try writer.execute("BEGIN IMMEDIATE")
            await #expect(throws: DeliverySQLite.Failure.self) {
                try await journal.conversionInstant(from: checkpoint)
            }
            try writer.execute("ROLLBACK")
            #expect(try writer.query("SELECT key FROM producer_ledger") { try DeliverySQLite.text($0, 0) }.isEmpty)
            let instant = Date(timeIntervalSince1970: 1_800_000_000)
            #expect(try await journal.conversionInstant(from: checkpoint, at: instant) == instant)
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
            let payload = try DeliveryFixture.payload(sequence: 1, changes: ["retraction"])
            _ = try await reopened.stage(from: checkpoint, nextCursor: Data([1]), payloads: [payload], observedDeletions: [record])
            let connection = try DeliverySQLite(url: url)
            #expect(try connection.query("SELECT record_id FROM deletion_detection") { try DeliverySQLite.text($0, 0) }.isEmpty)
            connection.close()
            await reopened.close()
        }
    }
}
