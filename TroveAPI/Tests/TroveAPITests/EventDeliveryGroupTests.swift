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
    private enum Failure: Error { case conversion }

    @Test
    func aQueryGroupCommitsEveryEventWithOneCursorAndReopensExactly() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let ids = try await journal.stage(from: checkpoint, nextCursor: Data([1]), changeCount: 3) { index, sequence in
                #expect(sequence == index + 1)
                return DeliveryFixture.payload(sequence: sequence, changes: ["add:\(index)"])
            }
            #expect(ids.count == 3)
            #expect(Set(ids).count == 3)
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
    func aFailedMemberRollsBackEarlierMembersCursorAndSequence(failingIndex: Int) async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            await #expect(throws: Failure.self) {
                try await journal.stage(from: checkpoint, nextCursor: Data([1]), changeCount: 3) { index, sequence in
                    if index == failingIndex { throw Failure.conversion }
                    return DeliveryFixture.payload(sequence: sequence, changes: ["add:\(index)"])
                }
            }
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
            _ = try await journal.stage(from: checkpoint, nextCursor: Data([1]), changeCount: 3) { index, sequence in
                #expect(sequence == index + 1)
                return DeliveryFixture.payload(sequence: sequence, changes: ["add:\(index)"])
            }
        }
    }

    @Test
    func aGroupCannotPartiallyCommitAtCapacity() async throws {
        try await DeliveryFixture.withJournal(limits: .init(maximumEvents: 1)) { journal, _ in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            await #expect(throws: EventDeliveryJournal.JournalError.capacityExceeded) {
                try await journal.stage(from: checkpoint, nextCursor: Data([1]), changeCount: 2) { index, sequence in
                    DeliveryFixture.payload(sequence: sequence, changes: ["add:\(index)"])
                }
            }
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
        }
    }

    @Test(arguments: [-1, 129])
    func invalidGroupCountsNeverInvokeTheBuilder(count: Int) async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            await #expect(throws: EventDeliveryJournal.JournalError.invalidConfiguration) {
                try await journal.stage(from: checkpoint, nextCursor: Data([1]), changeCount: count) { _, _ in
                    throw Failure.conversion
                }
            }
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
        }
    }

    @Test
    func policyExclusionsDoNotConsumeSequencesOrCapacity() async throws {
        try await DeliveryFixture.withJournal(limits: .init(maximumEvents: 1)) { journal, _ in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let ids = try await journal.stage(from: checkpoint, nextCursor: Data([1]), changeCount: 3) { index, sequence in
                #expect(sequence == (index == 2 ? 2 : 1))
                return index == 1 ? DeliveryFixture.payload(sequence: sequence, changes: ["eligible"]) : nil
            }
            #expect(ids.count == 1)
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID).cursor == Data([1]))
        }
    }

    @Test
    func unsupportedChangesAfterAnExclusionStillRollBackTheWholeDelta() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            await #expect(throws: Failure.self) {
                try await journal.stage(from: checkpoint, nextCursor: Data([1]), changeCount: 3) { index, sequence in
                    if index == 0 {
                        return nil
                    }
                    if index == 2 { throw Failure.conversion }
                    return DeliveryFixture.payload(sequence: sequence, changes: ["eligible"])
                }
            }
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
            _ = try await journal.stage(from: checkpoint, nextCursor: Data([1]), changeCount: 1) { _, sequence in
                #expect(sequence == 1)
                return DeliveryFixture.payload(sequence: sequence, changes: ["retry"])
            }
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
