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


struct DeliveryQueryCheckpointTests {
    @Test
    func backfillAndLiveCursorsAdvanceIndependentlyUsingOneSourceAndQueue() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let live = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let historical = try await journal.createQuery(for: live.sourceID, queryID: UUID(), definition: Data("six-month-history".utf8))
            #expect(historical.epoch == live.epoch && historical.sourceID == live.sourceID)
            #expect(historical.queryID != live.queryID && historical.cursor == nil)
            let payload = try DeliveryFixture.payload(sequence: 1, changes: ["same-native-sample"])
            let historyIDs = try await journal.stage(from: historical, nextCursor: Data([1]), payloads: [payload])
            #expect(try await journal.checkpoint(for: live.sourceID) == live)
            // Overlap commits the same exact bytes once while acknowledging each independent cursor.
            let liveIDs = try await journal.stage(from: live, nextCursor: Data([2]), payloads: [payload])
            #expect(liveIDs == historyIDs)
            #expect(try await journal.pendingDeliveryIDs() == historyIDs)
            #expect(try await journal.sourceSetups().count == 1)
            let checkpoints = try await journal.checkpoints(for: live.sourceID)
            #expect(checkpoints.count == 2)
            #expect(checkpoints.first { $0.queryID == historical.queryID }?.cursor == Data([1]))
            #expect(checkpoints.first { $0.queryID == live.queryID }?.cursor == Data([2]))
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            #expect(try await reopened.checkpoints(for: live.sourceID) == checkpoints)
            #expect(try await reopened.pendingDeliveryIDs() == historyIDs)
            await #expect(throws: DeliveryJournalError.staleCheckpoint) {
                try await reopened.stage(from: historical, nextCursor: Data([3]), payloads: [])
            }
            #expect(try await reopened.checkpoints(for: live.sourceID) == checkpoints)
            await reopened.close()
        }
    }

    @Test
    func pendingBackfillConversionSurvivesAnotherQueryCommitAndProcessReopen() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let live = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let historical = try await journal.createQuery(for: live.sourceID, queryID: UUID(), definition: Data([2]))
            let instant = Date(timeIntervalSince1970: 1_800_000_000)
            #expect(try await journal.conversionInstant(from: historical, at: instant) == instant)
            #expect(try await journal.conversionInstant(from: live, at: instant.addingTimeInterval(1)) == instant.addingTimeInterval(1))
            _ = try await journal.stage(from: live, nextCursor: Data([1]), payloads: [])
            await #expect(throws: EventSubmissionCommitment.ValidationError.invalidEnvelope) {
                try await journal.stage(from: historical, nextCursor: Data([2]), payloads: [.init(bytes: Data(), targets: [])])
            }
            #expect(try await journal.checkpoint(for: live.sourceID, queryID: historical.queryID) == historical)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            #expect(try await reopened.conversionInstant(from: historical, at: instant.addingTimeInterval(60)) == instant)
            let liveAfter = try await reopened.checkpoint(for: live.sourceID)
            #expect(try await reopened.conversionInstant(from: liveAfter, at: instant.addingTimeInterval(60)) == instant.addingTimeInterval(60))
            await reopened.close()
        }
    }

    @Test
    func oneQueryCannotRetireAnotherQueriesPendingDeletionBounds() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let live = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let historical = try await journal.createQuery(for: live.sourceID, queryID: UUID(), definition: Data([2]))
            let record = UUID()
            let instant = Date(timeIntervalSince1970: 1_800_000_000)
            _ = try await journal.deletionDetections(for: [record], from: live, at: instant)
            let retained = try await journal.deletionDetections(for: [record], from: historical, at: instant.addingTimeInterval(1))
            _ = try await journal.stage(from: live, nextCursor: Data([1]), payloads: [], observedDeletions: [record])
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let retry = try await reopened.deletionDetections(for: [record], from: historical, at: instant.addingTimeInterval(3600))
            #expect(retry == retained)
            #expect(retry[record] == instant.addingTimeInterval(1))
            await reopened.close()
        }
    }

    @Test
    func queryLimitsAndConflictsPreserveExistingProgress() async throws {
        try await DeliveryFixture.withJournal(limits: .init(maximumQueries: 2)) { journal, _ in
            let live = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let historical = try await journal.createQuery(for: live.sourceID, queryID: UUID(), definition: Data([2]))
            let before = try await journal.checkpoints(for: live.sourceID)
            await #expect(throws: DeliveryJournalError.queryConflict) {
                try await journal.createQuery(for: live.sourceID, queryID: historical.queryID, definition: Data([3]))
            }
            await #expect(throws: DeliveryJournalError.capacityExceeded) {
                try await journal.createQuery(for: live.sourceID, queryID: UUID(), definition: Data([3]))
            }
            // Source creation must also roll back its key and primary query when the query limit is exhausted.
            await #expect(throws: DeliveryJournalError.capacityExceeded) {
                try await journal.createSource(localID: UUID(), queryDefinition: Data([4]))
            }
            #expect(try await journal.sourceSetups().count == 1)
            #expect(try await journal.checkpoints(for: live.sourceID) == before)
        }
    }

    @Test
    func revocationStopsAllQueriesWithoutDiscardingTheirCursors() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let live = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let historical = try await journal.createQuery(for: live.sourceID, queryID: UUID(), definition: Data([2]))
            let setup = try await journal.sourceSetup(for: live.epoch)
            var binding = try #require(setup.binding)
            binding.source.revokedAt = binding.source.createdAt
            try await journal.confirmSource(binding, for: setup)
            for checkpoint in [live, historical] {
                await #expect(throws: DeliveryJournalError.sourceRevoked) {
                    try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: [])
                }
                await #expect(throws: DeliveryJournalError.sourceRevoked) { try await journal.conversionInstant(from: checkpoint) }
                #expect(try await journal.checkpoint(for: live.sourceID, queryID: checkpoint.queryID) == checkpoint)
            }
            await #expect(throws: DeliveryJournalError.sourceRevoked) {
                try await journal.createQuery(for: live.sourceID, queryID: UUID(), definition: Data([3]))
            }
        }
    }

    @Test
    func queryDiscoveryRejectsCorruptionRatherThanHidingWork() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let live = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let historical = try await journal.createQuery(for: live.sourceID, queryID: UUID(), definition: Data([2]))
            let connection = try DeliverySQLite(url: url)
            defer { connection.close() }
            try connection.execute("PRAGMA ignore_check_constraints = ON")
            try connection.execute(
                "UPDATE acquisition_query SET cursor = zeroblob(65537) WHERE id = ?", [.text(historical.queryID.uuidString.lowercased())]
            )
            await #expect(throws: DeliveryJournalError.corruptJournal) { try await journal.checkpoints(for: live.sourceID) }
            #expect(try await journal.checkpoint(for: live.sourceID) == live)
        }
    }
}
