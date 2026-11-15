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


struct EnrollmentEndCollectionTests {
    private typealias Fixture = HeartRatePlannerFixture

    @Test
    func exactEndExcludesOnlyTheEndedEnrollmentAndDoesNotTurnMeasurementEndIntoExpiry() throws {
        let ended = Self.plan(ending: Fixture.date(200))
        let ongoing = Fixture.plan(start: -600, end: 50)
        let snapshot = try ParticipantCollectionSnapshot(
            plans: [ended, ongoing], enrollmentIDs: [ended, ongoing].compactMap { UUID(uuidString: $0.enrollmentId) }
        )
        #expect(try snapshot.active(at: Fixture.date(199)).consentIDs(forHeartRateAt: Fixture.date(0)).count == 2)
        let remaining = try snapshot.active(at: Fixture.date(200))
        #expect(remaining.permitsHeartRateAcquisition)
        #expect(try remaining.consentIDs(forHeartRateAt: Fixture.date(0)) == [#require(UUID(uuidString: ongoing.windows[0].consentId))])
        #expect(try snapshot.active(at: Fixture.date(200_000)).permitsHeartRateAcquisition)
    }

    @Test
    func expiredCheckpointCannotAdvanceOrEraseQueuedDataEvenWithoutARefresh() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let end = Date().addingTimeInterval(-1)
            var plan = Self.plan(ending: end)
            plan.asOf = end.addingTimeInterval(-1)
            plan.windows[0].start = end.addingTimeInterval(-100)
            plan.windows[0].requirements[0].start = end.addingTimeInterval(-1000)
            let queued = try await DeliveryFixture.stage(journal, changes: ["queued-before-end"])
            let state = try await Fixture.retain([plan], in: journal)
            let checkpoint = try await journal.collectionCheckpoint(for: DeliveryFixture.sourceID, state: state, at: end.addingTimeInterval(-1))
            try await journal.validateCheckpoint(checkpoint, at: end.addingTimeInterval(-0.001))
            await #expect(throws: DeliveryJournalError.staleCheckpoint) { try await journal.validateCheckpoint(checkpoint, at: end) }
            await #expect(throws: DeliveryJournalError.staleCheckpoint) {
                try await journal.stage(from: checkpoint, nextCursor: Data([9]), payloads: [])
            }
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID).cursor == checkpoint.cursor)
            #expect(try await journal.pendingDeliveryIDs() == queued)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let restored = try await reopened.collectionState()
            #expect(restored.collections.first?.plan.endsAt == end)
            #expect(restored.stoppedEnrollmentIDs.isEmpty, "Enrollment expiry is not withdrawal.")
            await #expect(throws: ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized) {
                try await reopened.collectionCheckpoint(for: DeliveryFixture.sourceID, state: restored)
            }
            #expect(try await reopened.pendingDeliveryIDs() == queued)
            await reopened.close()
        }
    }

    @Test
    func plannerDoesNotScheduleAnEndedStudyAndFencesEveryReturnedCheckpoint() async throws {
        try await DeliveryFixture.withJournal(query: Fixture.definition()) { journal, _ in
            var first = Self.plan(ending: Fixture.date(200))
            first.windows[0].requirements[0].end = Fixture.date(-300)
            let ongoing = Fixture.plan(start: 0)
            let state = try await Fixture.retain([first, ongoing], in: journal)
            let before = try await journal.healthKitQueryPlan(for: DeliveryFixture.sourceID, state: state, at: Fixture.date(150))
            #expect(before.queries.allSatisfy { $0.checkpoint.acquisitionDeadline == Fixture.date(200) })
            await #expect(throws: DeliveryJournalError.staleCollectionState) {
                try await journal.finishHealthKitQuerySweep(before, state: state, at: Fixture.date(200))
            }
            let after = try await journal.healthKitQueryPlan(for: DeliveryFixture.sourceID, state: state, at: Fixture.date(200))
            #expect(after.queries.allSatisfy { $0.checkpoint.acquisitionDeadline == nil })
            #expect(after.queries.count < before.queries.count)
        }
    }

    @Test
    func aRefreshCannotRenewTheEnrollmentEnd() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let plan = Self.plan(ending: Fixture.date(200))
            let retained = try await Fixture.retain([plan], in: journal)
            var renewed = plan
            renewed.endsAt = Fixture.date(300)
            renewed.windows[0].end = renewed.endsAt
            renewed.windows[0].requirements[0].end = renewed.endsAt
            renewed.stateVersion += 1
            await #expect(throws: DeliveryJournalError.staleCollectionState) { try await Fixture.retain([renewed], in: journal) }
            #expect(try await journal.collectionState().revision == retained.revision)
        }
    }
}


extension EnrollmentEndCollectionTests {
    private static func plan(ending end: Date) -> Components.Schemas.ParticipantCollectionPlan {
        var plan = Fixture.plan()
        plan.endsAt = end
        plan.windows[0].end = end
        plan.windows[0].requirements[0].end = end
        return plan
    }
}
