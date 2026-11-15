//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPIClient
@testable import TroveSensorKit


struct SensorKitReplayEvidenceTests {
    @Test
    func firstEvidenceSurvivesReopenAndConflictingRetryCannotAdvance() async throws {
        let fixture = SensorKitJournalFixture()
        try await fixture.withJournal { journal, url in
            let batch = try fixture.batch()
            let checkpoint = try await journal.checkpoint(for: fixture.sourceID)
            let evidence = try evidence(batch, receipt: Data("original-facts".utf8))
            try await journal.prepareSensorKitBatch(from: checkpoint, nextCursor: Data("prepared".utf8), evidence: evidence)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: fixture.scope, mode: .openExisting)
            let retained = try await reopened.sensorKitBatchEvidence(
                sourceID: fixture.sourceID,
                sourceTypeIdentifier: batch.sourceToken,
                deviceProductType: batch.deviceProductType,
                coordinate: batch.coordinate
            )
            #expect(retained == evidence)
            let before = try await reopened.checkpoint(for: fixture.sourceID)
            let changed = try self.evidence(batch, receipt: Data("different-facts".utf8))
            await #expect(throws: DeliveryJournalError.eventIdentityMismatch) {
                try await reopened.prepareSensorKitBatch(from: before, nextCursor: Data("must-not-advance".utf8), evidence: changed)
            }
            #expect(try await reopened.checkpoint(for: fixture.sourceID) == before)
            let page = try await reopened.sensorKitBatchEvidencePage(sourceID: fixture.sourceID, sourceTypeIdentifier: batch.sourceToken, limit: 1)
            #expect(page.map(\.evidence) == [evidence])
            let last = try #require(page.last)
            #expect(try await reopened.sensorKitBatchEvidencePage(
                sourceID: fixture.sourceID, sourceTypeIdentifier: batch.sourceToken, after: last.rowID
            ).isEmpty)
            let usage = try await reopened.sensorKitEvidenceUsage(sourceID: fixture.sourceID)
            #expect(usage.batches == 1 && usage.retainedBytes > evidence.firstReceipt.count)
            await reopened.close()
        }
    }

    @Test
    func evidenceBudgetRefusalRollsBackPreparedCursorAndInsertion() async throws {
        let fixture = SensorKitJournalFixture()
        try await fixture.withJournal(limits: .init(maximumBytes: 32_768)) { journal, _ in
            let batch = try fixture.batch()
            let before = try await journal.checkpoint(for: fixture.sourceID)
            let large = try evidence(batch, receipt: Data(repeating: 0x41, count: 65_536))
            await #expect(throws: DeliveryJournalError.capacityExceeded) {
                try await journal.prepareSensorKitBatch(from: before, nextCursor: Data("prepared".utf8), evidence: large)
            }
            #expect(try await journal.checkpoint(for: fixture.sourceID) == before)
            #expect(try await journal.sensorKitEvidenceUsage(sourceID: fixture.sourceID).batches == 0)
        }
    }

    @Test
    func authorityIsRecordedOnlyWithCompletedStagingAndRemainsTheFirstAuthority() async throws {
        let fixture = SensorKitJournalFixture()
        try await fixture.withJournal { journal, _ in
            let batch = try fixture.batch()
            let initial = try await journal.checkpoint(for: fixture.sourceID)
            let retained = try evidence(batch, receipt: Data("first-facts".utf8))
            try await journal.prepareSensorKitBatch(from: initial, nextCursor: Data("prepared".utf8), evidence: retained)
            let firstPage = try await journal.sensorKitBatchEvidencePage(sourceID: fixture.sourceID, sourceTypeIdentifier: batch.sourceToken)
            #expect(firstPage.first?.stagedAuthority == nil)
            let before = try await journal.checkpoint(for: fixture.sourceID)
            _ = try await journal.stageSensorKitBatch(
                from: before, nextCursor: Data("staged".utf8), payloads: [], evidence: retained, authority: String(repeating: "a", count: 64)
            )
            let second = try await journal.checkpoint(for: fixture.sourceID)
            _ = try await journal.stageSensorKitBatch(
                from: second, nextCursor: Data("restaged".utf8), payloads: [], evidence: retained, authority: String(repeating: "b", count: 64)
            )
            let page = try await journal.sensorKitBatchEvidencePage(sourceID: fixture.sourceID, sourceTypeIdentifier: batch.sourceToken)
            #expect(page.first?.stagedAuthority == String(repeating: "a", count: 64))
            #expect(page.first?.evidence == retained)
        }
    }

    private func evidence(_ batch: SensorKitAcquisition.Batch, receipt: Data) throws -> SensorKitBatchEvidence {
        try .init(
            sourceTypeIdentifier: batch.sourceToken,
            deviceProductType: batch.deviceProductType,
            coordinate: batch.coordinate,
            effectiveStart: batch.facts.conversionInstant,
            effectiveEnd: batch.facts.conversionInstant,
            replayToken: Data("bounded-native-token".utf8),
            firstReceipt: receipt
        )
    }
}
