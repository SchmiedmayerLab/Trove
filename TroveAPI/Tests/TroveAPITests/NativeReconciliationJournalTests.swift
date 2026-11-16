//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import CTroveDeliverySQLite
import Foundation
import Testing
@testable import TroveAPIClient


struct NativeReconciliationJournalTests {
    private typealias Fixture = HeartRatePlannerFixture

    private static func setup(
        _ journal: EventDeliveryJournal, at now: Date
    ) async throws -> (ParticipantCollectionState, Components.Schemas.NativeCollectionReconciliationInstruction) {
        var plan = Fixture.plan(start: 100, end: 150)
        plan.asOf = now
        plan.endsAt = now.addingTimeInterval(-100)
        plan.windows[0].start = now.addingTimeInterval(-1_000)
        plan.windows[0].end = plan.endsAt
        plan.windows[0].requirements[0].profile = CollectionObservationProfile.sleepStage.rawValue
        plan.windows[0].requirements[0].sourceTypeIdentifier = HealthKitQueryDefinition.Stream.sleepStage.sourceTypeIdentifier
        plan.windows[0].requirements[0].start = now.addingTimeInterval(-500)
        plan.windows[0].requirements[0].end = plan.endsAt
        let state = try await Fixture.retain([plan], in: journal)
        let window = try #require(plan.windows.first)
        let requirement = try #require(window.requirements.first)
        let value = Components.Schemas.NativeCollectionReconciliationInstruction(
            id: UUID().uuidString,
            sourceId: DeliveryFixture.sourceID.uuidString,
            enrollmentId: plan.enrollmentId,
            studyId: plan.studyId,
            stateVersion: plan.stateVersion,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(900),
            consentId: window.consentId,
            publicationId: window.publicationId,
            revision: window.revision,
            profile: requirement.profile,
            sourceTypeIdentifier: try #require(requirement.sourceTypeIdentifier),
            start: requirement.start,
            end: try #require(requirement.end),
            includeWorkoutRoutes: false
        )
        return (state, value)
    }

    @Test
    func finiteCompletionSurvivesReopenRenewalAndLostServerAcknowledgement() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let now = Date()
            let (state, value) = try await Self.setup(journal, at: now)
            let id = try #require(UUID(uuidString: value.id))
            let ordinaryBefore = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            try await journal.retainNativeReconciliations([value], for: DeliveryFixture.sourceID, replacing: state, at: now)
            let selection = try await journal.nativeReconciliationSelection(id: id, sourceID: DeliveryFixture.sourceID, state: state, at: now)
            _ = try await journal.stage(from: selection.checkpoint, nextCursor: Data([1]), payloads: [], queryExhausted: true)
            #expect(try await journal.completedNativeReconciliations(for: DeliveryFixture.sourceID).map(\.id) == [id])
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let restored = try await reopened.collectionState()
            var renewed = value
            renewed.issuedAt = now.addingTimeInterval(1)
            renewed.expiresAt = now.addingTimeInterval(901)
            try await reopened.retainNativeReconciliations([renewed], for: DeliveryFixture.sourceID, replacing: restored, at: renewed.issuedAt)
            await #expect(throws: EventDeliveryJournal.JournalError.staleCheckpoint) {
                try await reopened.nativeReconciliationSelection(id: id, sourceID: DeliveryFixture.sourceID, state: restored, at: renewed.issuedAt)
            }
            #expect(try await reopened.completedNativeReconciliations(for: DeliveryFixture.sourceID).map(\.id) == [id])
            try await reopened.acknowledgeNativeReconciliation(id, sourceID: DeliveryFixture.sourceID)
            #expect(try await reopened.completedNativeReconciliations(for: DeliveryFixture.sourceID).isEmpty)
            #expect(try await reopened.checkpoint(for: DeliveryFixture.sourceID).cursor == ordinaryBefore.cursor)
            #expect(try await reopened.checkpoint(for: DeliveryFixture.sourceID, queryID: id).cursor == Data([1]))
            await reopened.close()
        }
    }

    @Test
    func expirationAndLocalWithdrawalFenceAnAlreadySelectedPage() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let now = Date()
            let (state, value) = try await Self.setup(journal, at: now)
            let id = try #require(UUID(uuidString: value.id))
            try await journal.retainNativeReconciliations([value], for: DeliveryFixture.sourceID, replacing: state, at: now)
            let selection = try await journal.nativeReconciliationSelection(id: id, sourceID: DeliveryFixture.sourceID, state: state, at: now)
            await #expect(throws: EventDeliveryJournal.JournalError.staleCheckpoint) {
                try await journal.validateCheckpoint(selection.checkpoint, at: value.expiresAt)
            }
            let enrollmentID = try #require(UUID(uuidString: value.enrollmentId))
            _ = try await journal.stopCollection(for: [enrollmentID], replacing: state)
            await #expect(throws: EventDeliveryJournal.JournalError.staleCheckpoint) {
                try await journal.stage(from: selection.checkpoint, nextCursor: Data([1]), payloads: [], queryExhausted: true)
            }
            await #expect(throws: EventDeliveryJournal.JournalError.staleCollectionState) {
                try await journal.retainNativeReconciliations([value], for: DeliveryFixture.sourceID, replacing: state, at: now)
            }
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID, queryID: id).cursor == nil)
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
        }
    }

    @Test
    func format19JournalGainsTheReconciliationTableWithoutLosingQueuedWork() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let ids = try await DeliveryFixture.stage(journal, changes: ["queued-before-upgrade"])
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            await journal.close()
            // Only removes the new, empty additive table from this test's own disposable journal.
            let database = try DeliverySQLite(url: url)
            try database.transaction {
                try database.execute("DROP TABLE native_collection_reconciliation")
                try database.execute("PRAGMA user_version = 19")
            }
            database.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            #expect(try await reopened.pendingDeliveryIDs() == ids)
            #expect(try await reopened.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
            let now = Date()
            let (state, value) = try await Self.setup(reopened, at: now)
            try await reopened.retainNativeReconciliations([value], for: DeliveryFixture.sourceID, replacing: state, at: now)
            await reopened.close()
            let inspection = try DeliverySQLite(url: url)
            #expect(try inspection.query("PRAGMA user_version") { sqlite3_column_int64($0, 0) } == [20])
            inspection.close()
        }
    }
}
