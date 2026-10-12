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


struct EventDeliveryJournalTests {
    @Test
    func originalBytesIdentityAndUncertainAttemptSurviveReopening() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let ids = try await DeliveryFixture.stage(journal, changes: ["add:a", "add:b"])
            let id = try #require(ids.first)
            let initial = try #require(await journal.prepareAttempt(id))
            #expect(!initial.custodyWasUncertain)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let retried = try #require(await reopened.prepareAttempt(id))
            #expect(retried.custodyWasUncertain)
            #expect(retried.bytes == initial.bytes)
            #expect(retried.commitment.receiptLookup == initial.commitment.receiptLookup)
            #expect(try await reopened.checkpoint(for: DeliveryFixture.sourceID).cursor != nil)
            await #expect(throws: EventDeliveryJournal.JournalError.staleCheckpoint) {
                try await reopened.stage(from: checkpoint, nextCursor: Data([2]), payloads: [.init(bytes: Data(), targets: [])])
            }
            await reopened.close()
        }
    }

    @Test
    func emptyDeltaAdvancesCheckpointWithoutConsumingEventIdentity() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let initial = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let empty = try await journal.stage(from: initial, nextCursor: Data([1]), payloads: [])
            #expect(empty.isEmpty)
            let next = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            #expect(next.cursor == Data([1]))
            #expect(next != initial)
            let ids = try await journal.stage(from: next, nextCursor: Data([2]), payloads: [DeliveryFixture.payload(sequence: 1, changes: ["add:a"])])
            let id = try #require(ids.first)
            let pending = try await journal.pendingDeliveryIDs()
            #expect(pending == [id])
        }
    }

    @Test
    func invalidPayloadDoesNotAcknowledgeChanges() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            await #expect(throws: EventSubmissionCommitment.ValidationError.invalidEnvelope) {
                try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: [.init(bytes: Data(), targets: [])])
            }
            let pending = try await journal.pendingDeliveryIDs()
            #expect(pending.isEmpty)
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
            let id = try await journal.stage(
                from: checkpoint, nextCursor: Data([1]), payloads: [DeliveryFixture.payload(sequence: 1, changes: ["add:a"])]
            )
            #expect(!id.isEmpty)
        }
    }

    @Test
    func verifiedCustodyAtomicallyRetiresPayloadAndPreservesCheckpoint() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let id = try #require(await DeliveryFixture.stage(journal, changes: ["add:a"]).first)
            let attempt = try #require(await journal.prepareAttempt(id))
            let receipt = DeliveryFixture.receipt(attempt)
            var altered = receipt
            altered.targetIntentSHA256 = String(repeating: "0", count: 64)
            await #expect(throws: EventSubmissionCommitment.ValidationError.receiptMismatch) {
                try await journal.recordReceipt(altered, for: id)
            }
            #expect(try await journal.pendingDeliveryIDs() == [id])
            try await journal.recordReceipt(receipt, for: id)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            #expect(try await reopened.receipt(for: id) == receipt)
            #expect(try await reopened.pendingDeliveryIDs().isEmpty)
            #expect(try await reopened.prepareAttempt(id) == nil)
            #expect(try await reopened.checkpoint(for: DeliveryFixture.sourceID).cursor != nil)
            try await reopened.recordReceipt(receipt, for: id)
            var different = receipt
            different.eventId = UUID().uuidString
            await #expect(throws: EventDeliveryJournal.JournalError.receiptConflict) {
                try await reopened.recordReceipt(different, for: id)
            }
            await reopened.close()
        }
    }

    @Test
    func accountAndSourceEpochCannotBeRebound() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let wrongScope = EventDeliveryJournal.Scope(
                backend: DeliveryFixture.scope.backend, issuer: DeliveryFixture.scope.issuer, subject: "participant-b"
            )
            #expect(throws: EventDeliveryJournal.JournalError.wrongScope) {
                try EventDeliveryJournal(url: url, scope: wrongScope, mode: .openExisting)
            }
            let setup = try await journal.sourceSetup(for: DeliveryFixture.epoch)
            var changed = try #require(setup.binding)
            changed.identifierRoot = "https://trove.test/replacement"
            changed.eventIdentifierSystem = changed.identifierRoot + "/NamingSystem/grove-event-v0"
            await #expect(throws: EventDeliveryJournal.JournalError.sourceConflict) { try await journal.confirmSource(changed, for: setup) }
            await #expect(throws: EventDeliveryJournal.JournalError.sourceConflict) {
                try await journal.createSource(localID: DeliveryFixture.epoch, queryDefinition: Data("different-predicate".utf8))
            }
            #expect(throws: (any Error).self) {
                try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .createNew)
            }
            let pending = try await journal.pendingDeliveryIDs()
            #expect(pending.isEmpty)
        }
    }

    @Test(arguments: ["bytes", "events"])
    func boundedStorageDoesNotEvictPendingWork(bound: String) async throws {
        let binding = DeliveryFixture.binding(sourceID: DeliveryFixture.sourceID, registrationID: DeliveryFixture.epoch)
        let setupBytes = try JSONEncoder().encode(binding).count + DeliveryFixture.queryDefinition.count + 32
        let limits = EventDeliveryJournal.Limits(
            maximumBytes: bound == "bytes" ? setupBytes + 100 : 65_536,
            maximumEvents: bound == "events" ? 1 : 10
        )
        try await DeliveryFixture.withJournal(limits: limits) { journal, _ in
            let previous = bound == "bytes" ? [] : try await DeliveryFixture.stage(journal, changes: ["add:a"])
            await #expect(throws: EventDeliveryJournal.JournalError.capacityExceeded) {
                try await DeliveryFixture.stage(journal, changes: ["add:b"])
            }
            #expect(try await journal.pendingDeliveryIDs() == previous)
        }
    }

    @Test
    func concurrentDuplicateStagingHasOneIdentity() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let successes = try await withThrowingTaskGroup(of: Int.self, returning: Int.self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        do {
                            _ = try await journal.stage(
                                from: checkpoint, nextCursor: Data([1]), payloads: [DeliveryFixture.payload(sequence: 1, changes: ["add:a"])]
                            )
                            return 1
                        } catch EventDeliveryJournal.JournalError.staleCheckpoint {
                            return 0
                        }
                    }
                }
                return try await group.reduce(0, +)
            }
            #expect(successes == 1)
            #expect(try await journal.pendingDeliveryIDs().count == 1)
        }
    }

    @Test
    func failureAfterPayloadInsertionRollsBackAllStagingState() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let connection = try DeliverySQLite(url: url)
            try connection.execute("""
                CREATE TRIGGER fail_staging BEFORE UPDATE OF cursor ON source_state
                BEGIN SELECT RAISE(ABORT, 'injected staging failure'); END
                """)
            await #expect(throws: DeliverySQLite.Failure.self) {
                try await DeliveryFixture.stage(journal, changes: ["add:a"])
            }
            let pending = try await journal.pendingDeliveryIDs()
            #expect(pending.isEmpty)
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
            try connection.execute("DROP TRIGGER fail_staging")
            connection.close()
            let id = try await journal.stage(
                from: checkpoint, nextCursor: Data([1]), payloads: [DeliveryFixture.payload(sequence: 1, changes: ["add:a"])]
            )
            #expect(!id.isEmpty)
        }
    }

    @Test
    func failureDuringCustodyUpdatePreservesPayloadAndPendingState() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let id = try #require(await DeliveryFixture.stage(journal, changes: ["add:a"]).first)
            let attempt = try #require(await journal.prepareAttempt(id))
            let connection = try DeliverySQLite(url: url)
            try connection.execute("""
                CREATE TRIGGER fail_custody BEFORE UPDATE OF receipt ON delivery
                BEGIN SELECT RAISE(ABORT, 'injected custody failure'); END
                """)
            await #expect(throws: DeliverySQLite.Failure.self) {
                try await journal.recordReceipt(DeliveryFixture.receipt(attempt), for: id)
            }
            #expect(try await journal.receipt(for: id) == nil)
            let retry = try #require(await journal.prepareAttempt(id))
            #expect(retry.bytes == attempt.bytes)
            #expect(retry.custodyWasUncertain)
            connection.close()
        }
    }
}


extension EventDeliveryJournalTests {
    @Test
    func missingAndUnsupportedJournalsAreNotRecreated() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let missing = url.deletingLastPathComponent().appendingPathComponent("missing.sqlite")
            #expect {
                try EventDeliveryJournal(url: missing, scope: DeliveryFixture.scope, mode: .openExisting)
            } throws: {
                ($0 as? CocoaError)?.code == .fileReadNoSuchFile
            }
            #expect(!FileManager.default.fileExists(atPath: missing.path))
            await journal.close()
            let connection = try DeliverySQLite(url: url)
            try connection.execute("PRAGMA user_version = 999")
            connection.close()
            #expect(throws: EventDeliveryJournal.JournalError.unsupportedFormat) {
                try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            }
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test
    func sqliteFullPreservesPreviouslyStagedEventsAndRollsBackTheNewSequence() async throws {
        try await DeliveryFixture.withJournal(limits: .init(maximumDatabaseBytes: 128 * 1024)) { journal, url in
            let existing = try await DeliveryFixture.stage(journal, changes: ["add:a"])
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            do {
                let payload = DeliveryFixture.payload(sequence: 2, changes: ["add:b"])
                _ = try await journal.stage(from: checkpoint, nextCursor: Data([2]), payloads: [
                    .init(bytes: payload.bytes + Data(repeating: 32, count: 192 * 1024), targets: payload.targets)
                ])
                Issue.record("SQLite accepted an event larger than the configured database limit")
            } catch let failure as DeliverySQLite.Failure {
                #expect(failure.code == 13) // SQLITE_FULL, not the application-level quota error.
            }
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            #expect(try await reopened.pendingDeliveryIDs() == existing)
            #expect(try await reopened.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
            _ = try await reopened.stage(
                from: checkpoint, nextCursor: Data([2]), payloads: [DeliveryFixture.payload(sequence: 2, changes: ["add:b"])]
            )
            await reopened.close()
        }
    }

    @Test(arguments: [false, true])
    func corruptedCommitmentCannotBeSentOrReportedAsCustody(delivered: Bool) async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let id = try #require(await DeliveryFixture.stage(journal, changes: ["add:a"]).first)
            let attempt = try #require(await journal.prepareAttempt(id))
            if delivered { try await journal.recordReceipt(DeliveryFixture.receipt(attempt), for: id) }
            let connection = try DeliverySQLite(url: url)
            try connection.execute("UPDATE delivery SET payload_digest = ?", [.text(String(repeating: "0", count: 64))])
            connection.close()
            await #expect(throws: EventDeliveryJournal.JournalError.corruptJournal) { try await journal.prepareAttempt(id) }
            if delivered {
                await #expect(throws: EventDeliveryJournal.JournalError.corruptJournal) { try await journal.pruneDelivered() }
            }
        }
    }

    @Test
    func databaseSymlinksAreNotFollowed() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let link = url.deletingLastPathComponent().appendingPathComponent("linked.sqlite")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            #expect(throws: EventDeliveryJournal.JournalError.unsafeStorage) {
                try EventDeliveryJournal(url: link, scope: DeliveryFixture.scope, mode: .openExisting)
            }
            let pending = try await journal.pendingDeliveryIDs()
            #expect(pending.isEmpty)
        }
    }
}
