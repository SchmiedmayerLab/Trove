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


struct EventDeliveryCheckpointTests {
    @Test
    func aDifferentAccountCannotCommitAnotherAccountsCheckpoint() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let scope = EventDeliveryJournal.Scope(
                backend: DeliveryFixture.scope.backend, issuer: DeliveryFixture.scope.issuer, subject: "participant-b"
            )
            let otherURL = url.deletingLastPathComponent().appendingPathComponent("other.sqlite")
            let other = try EventDeliveryJournal(url: otherURL, scope: scope, mode: .createNew)
            await #expect(throws: EventDeliveryJournal.JournalError.wrongScope) {
                try await other.stage(from: checkpoint, nextCursor: Data([1]), payloads: [])
            }
            await other.close()
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
        }
    }

    @Test
    func boundedPruningNeverDeletesPendingWorkOrResetsTheCursor() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let first = try #require(await DeliveryFixture.stage(journal, changes: ["add:a"]).first)
            let second = try #require(await DeliveryFixture.stage(journal, changes: ["add:b"]).first)
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let attempt = try #require(await journal.prepareAttempt(first))
            try await journal.recordReceipt(DeliveryFixture.receipt(attempt), for: first)
            #expect(try await journal.pruneDelivered(limit: 1) == 1)
            #expect(try await journal.pruneDelivered() == 0)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            #expect(try await reopened.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
            #expect(try await reopened.pendingDeliveryIDs() == [second])
            _ = try await reopened.stage(
                from: checkpoint, nextCursor: Data([3]), payloads: [DeliveryFixture.payload(sequence: 3, changes: ["add:c"])]
            )
            await reopened.close()
        }
    }

    @Test
    func repeatedCustodyAndPruningStayWithinOneEventCapacity() async throws {
        try await DeliveryFixture.withJournal(limits: .init(maximumEvents: 1)) { journal, _ in
            for sequence in 1...64 {
                let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
                let ids = try await journal.stage(from: checkpoint, nextCursor: Data("cursor-\(sequence)".utf8), payloads: [
                    DeliveryFixture.payload(sequence: Int64(sequence), changes: ["add:\(sequence)"])
                ])
                let id = try #require(ids.first)
                let attempt = try #require(await journal.prepareAttempt(id))
                try await journal.recordReceipt(DeliveryFixture.receipt(attempt), for: id)
                #expect(try await journal.pruneDelivered() == 1)
            }
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
        }
    }

    @Test
    func aRepeatedOpaqueCursorDoesNotAllowAnOldCheckpointToCommit() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let initial = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            _ = try await journal.stage(from: initial, nextCursor: Data([1]), payloads: [])
            let before = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            _ = try await journal.stage(from: before, nextCursor: Data([1]), payloads: [])
            let after = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            #expect(before.cursor == after.cursor)
            #expect(before != after)
            await #expect(throws: EventDeliveryJournal.JournalError.staleCheckpoint) {
                try await journal.stage(from: before, nextCursor: Data([2]), payloads: [])
            }
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID) == after)
        }
    }

    @Test
    func failedPruningPreservesReceiptsAndCheckpoint() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let id = try #require(await DeliveryFixture.stage(journal, changes: ["add:a"]).first)
            let attempt = try #require(await journal.prepareAttempt(id))
            let receipt = DeliveryFixture.receipt(attempt)
            try await journal.recordReceipt(receipt, for: id)
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let connection = try DeliverySQLite(url: url)
            defer { connection.close() }
            try connection.execute("""
                CREATE TRIGGER fail_pruning BEFORE DELETE ON delivery
                BEGIN SELECT RAISE(ABORT, 'injected pruning failure'); END
                """)
            await #expect(throws: DeliverySQLite.Failure.self) { try await journal.pruneDelivered() }
            #expect(try await journal.receipt(for: id) == receipt)
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
        }
    }

    @Test
    func cancellationBeforeCommitDoesNotAdvanceCheckpointOrConsumeIdentity() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let task = Task { @concurrent in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: [
                    DeliveryFixture.payload(sequence: 1, changes: ["add:a"])
                ])
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
            _ = try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: [DeliveryFixture.payload(sequence: 1, changes: ["add:a"])])
        }
    }
}
