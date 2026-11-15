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


struct HealthKitRecordConversionTests {
    private static let configuration = Data("converter-build-1".utf8)
    private static let instant = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func previousConversionsAreBoundToTheSourceAndCurrentCheckpoint() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let first = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let record = UUID(), unknown = UUID(), otherID = UUID()
            _ = try await journal.healthKitConversionInstants(
                for: [record], configuration: Self.configuration, from: first, at: Self.instant
            )
            #expect(try await journal.previouslyConvertedHealthKitRecords([unknown, record], from: first) == [record])
            try await DeliveryFixture.register(journal, sourceID: otherID, query: Data([1]))
            let other = try await journal.checkpoint(for: otherID)
            #expect(try await journal.previouslyConvertedHealthKitRecords([record], from: other).isEmpty)
            _ = try await journal.stage(from: first, nextCursor: Data([1]), payloads: [])
            await #expect(throws: DeliveryJournalError.staleCheckpoint) {
                try await journal.previouslyConvertedHealthKitRecords([record], from: first)
            }
        }
    }

    @Test
    func overlappingQueriesAndRestartReuseTheFirstConversionTime() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let live = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let history = try await journal.createQuery(for: live.sourceID, queryID: UUID(), definition: Data([2]))
            let record = UUID()
            let first = try await journal.healthKitConversionInstants(
                for: [record], configuration: Self.configuration, from: live, at: Self.instant
            )
            _ = try await journal.stage(from: live, nextCursor: Data([1]), payloads: [])
            #expect(try await journal.healthKitConversionInstants(
                for: [record], configuration: Self.configuration, from: history, at: Self.instant.addingTimeInterval(60)
            ) == first)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            #expect(try await reopened.healthKitConversionInstants(
                for: [record], configuration: Self.configuration, from: history, at: Self.instant.addingTimeInterval(120)
            ) == first)
            #expect(first[record] == Self.instant)
            await reopened.close()
        }
    }

    @Test
    func changedConverterAndDifferentSourceHaveIndependentConversionTimes() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let first = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let sourceID = UUID(), record = UUID()
            try await DeliveryFixture.register(journal, sourceID: sourceID, query: Data([1]))
            let other = try await journal.checkpoint(for: sourceID)
            let original = try await journal.healthKitConversionInstants(
                for: [record], configuration: Self.configuration, from: first, at: Self.instant
            )
            let changed = try await journal.healthKitConversionInstants(
                for: [record], configuration: Data("converter-build-2".utf8), from: first, at: Self.instant.addingTimeInterval(60)
            )
            let separate = try await journal.healthKitConversionInstants(
                for: [record], configuration: Self.configuration, from: other, at: Self.instant.addingTimeInterval(120)
            )
            #expect(original[record] == Self.instant)
            #expect(changed[record] == Self.instant.addingTimeInterval(60))
            #expect(separate[record] == Self.instant.addingTimeInterval(120))
        }
    }

    @Test
    func staleCheckpointCannotRecordANewConversion() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let before = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            _ = try await journal.stage(from: before, nextCursor: Data([1]), payloads: [])
            let record = UUID()
            await #expect(throws: DeliveryJournalError.staleCheckpoint) {
                try await journal.healthKitConversionInstants(for: [record], configuration: Self.configuration, from: before, at: Self.instant)
            }
            let current = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let next = Self.instant.addingTimeInterval(60)
            #expect(try await journal.healthKitConversionInstants(
                for: [record], configuration: Self.configuration, from: current, at: next
            )[record] == next)
        }
    }

    @Test
    func capacityFailureRollsBackTheWholeRecordBatch() async throws {
        try await DeliveryFixture.withJournal(limits: .init(maximumBytes: 4096)) { journal, url in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let records = (0..<128).map { _ in UUID() }
            await #expect(throws: DeliveryJournalError.capacityExceeded) {
                try await journal.healthKitConversionInstants(for: records, configuration: Self.configuration, from: checkpoint, at: Self.instant)
            }
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let later = Self.instant.addingTimeInterval(60)
            let retried = try await reopened.healthKitConversionInstants(
                for: records, configuration: Self.configuration, from: checkpoint, at: later
            )
            #expect(retried.count == records.count && retried.values.allSatisfy { $0 == later })
            await reopened.close()
        }
    }
}
