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


struct EventDeliveryGroupTests {
    @Test
    func aQueryGroupCommitsEveryEventWithOneCursorAndReopensExactly() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let payloads = (1...3).map { DeliveryFixture.payload(sequence: Int64($0), changes: ["add:\($0)"]) }
            let ids = try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: payloads)
            #expect(ids.count == 3 && Set(ids).count == 3)
            let originals = try await Self.attempts(ids, in: journal)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let retries = try await Self.attempts(ids, in: reopened)
            #expect(retries.map(\.bytes) == originals.map(\.bytes))
            #expect(retries.map(\.commitment.receiptLookup) == originals.map(\.commitment.receiptLookup))
            #expect(retries.allSatisfy { $0.custodyWasUncertain })
            #expect(try await reopened.checkpoint(for: DeliveryFixture.sourceID).cursor == Data([1]))
            await reopened.close()
        }
    }

    @Test(arguments: [0, 1, 2])
    func aMalformedMemberRollsBackEarlierMembersAndCursor(failingIndex: Int) async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            var payloads = (1...3).map { DeliveryFixture.payload(sequence: Int64($0), changes: ["sample"]) }
            payloads[failingIndex] = .init(bytes: Data("invalid".utf8), targets: [])
            await #expect(throws: EventSubmissionCommitment.ValidationError.invalidEnvelope) {
                try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: payloads)
            }
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
        }
    }

    @Test
    func aGroupCannotPartiallyCommitAtCapacity() async throws {
        try await DeliveryFixture.withJournal(limits: .init(maximumEvents: 1)) { journal, _ in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let payloads = (1...2).map { DeliveryFixture.payload(sequence: Int64($0), changes: ["sample"]) }
            await #expect(throws: EventDeliveryJournal.JournalError.capacityExceeded) {
                try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: payloads)
            }
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
        }
    }

    @Test
    func oversizedGroupCannotAdvanceTheCursor() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let payloads = (1...129).map { DeliveryFixture.payload(sequence: Int64($0), changes: ["sample"]) }
            await #expect(throws: EventDeliveryJournal.JournalError.invalidConfiguration) {
                try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: payloads)
            }
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
        }
    }

    @Test
    func wireSequenceBelongsToTheProducerNotTheQueue() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let producer = UUID()
            let payload = DeliveryFixture.payload(sequence: 42, changes: ["sample"], producerID: producer)
            let ids = try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: [payload])
            let id = try #require(ids.first)
            let attempt = try #require(await journal.prepareAttempt(id))
            #expect(attempt.bytes == payload.bytes)
            #expect(attempt.commitment.producerEventIdentifier.value == "e0:\(producer.uuidString.lowercased()):42")
        }
    }

    @Test
    func anotherSourcesNamespaceCannotBeStaged() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let payload = DeliveryFixture.payload(sequence: 1, changes: ["sample"], sourceID: UUID())
            await #expect(throws: DeliveryJournalError.eventIdentityMismatch) {
                try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: [payload])
            }
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
        }
    }

    @Test
    func duplicateEventIdentityCannotCommitTwoQueueRows() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let payload = DeliveryFixture.payload(sequence: 1, changes: ["sample"])
            await #expect(throws: DeliverySQLite.Failure.self) {
                try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: [payload, payload])
            }
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
        }
    }
}


extension EventDeliveryGroupTests {
    private static func attempts(_ ids: [UUID], in journal: EventDeliveryJournal) async throws -> [EventDeliveryJournal.Attempt] {
        var attempts: [EventDeliveryJournal.Attempt] = []
        for id in ids { attempts.append(try #require(await journal.prepareAttempt(id))) }
        return attempts
    }
}
