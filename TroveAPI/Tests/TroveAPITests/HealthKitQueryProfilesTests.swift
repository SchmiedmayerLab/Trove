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


struct HealthKitQueryProfilesTests {
    private typealias Fixture = HeartRatePlannerFixture
    private static let sourceID = DeliveryFixture.sourceID

    @Test
    func workoutAddsItsOwnLiveAndHistoricalQueriesWithoutChangingOtherCursors() async throws {
        try await DeliveryFixture.withJournal(query: Fixture.definition()) { journal, _ in
            let heart = Fixture.plan(start: -600), sleep = Self.sleepPlan(start: -900)
            let previous = try await Fixture.retain([heart, sleep], in: journal)
            let plan = try await journal.healthKitQueryPlan(for: Self.sourceID, state: previous, at: Fixture.liveStart)
            for query in plan.queries {
                _ = try await journal.stage(from: query.checkpoint, nextCursor: Data([7]), payloads: [], queryExhausted: true)
            }
            var workout = Fixture.plan(start: -1200)
            workout.windows[0].requirements[0].profile = CollectionObservationProfile.workout.rawValue
            let next = try await Fixture.retain([heart, sleep, workout], in: journal)
            let extended = try await journal.healthKitQueryPlan(for: Self.sourceID, state: next, at: Fixture.date(200))
            #expect(extended.queries.count == 6)
            #expect(Set(extended.liveQueries.map { $0.definition.profile }) == [.heartRate, .sleepStage, .workout])
            #expect(extended.queries.filter { $0.definition.profile != .workout }.allSatisfy { $0.checkpoint.cursor == Data([7]) })
            #expect(extended.queries.filter { $0.definition.profile == .workout }.allSatisfy { $0.checkpoint.cursor == nil })
            let snapshot = try #require(next.snapshot)
            #expect(try snapshot.consentIDs(profile: .workout, start: Fixture.date(-1300), end: Fixture.date(-1100)).count == 1)
            #expect(throws: ParticipantCollectionSnapshot.CollectionError.invalidPlan) {
                try snapshot.consentIDs(profile: .workout, start: Fixture.date(-1300), end: nil)
            }
        }
    }

    @Test
    func bothMeasurementsHaveIndependentHistoryAndLiveCursorsUnderOneSource() async throws {
        try await DeliveryFixture.withJournal(query: Fixture.definition()) { journal, url in
            let heart = Fixture.plan(start: -600), sleep = Self.sleepPlan(start: -900)
            let state = try await Fixture.retain([heart, sleep], in: journal)
            let plan = try await journal.healthKitQueryPlan(for: Self.sourceID, state: state, at: Fixture.liveStart)
            #expect(plan.queries.count == 4)
            #expect(Set(plan.liveQueries.map { $0.definition.profile }) == [.heartRate, .sleepStage])
            for (index, query) in plan.queries.enumerated() {
                _ = try await journal.stage(from: query.checkpoint, nextCursor: Data([UInt8(index + 1)]), payloads: [], queryExhausted: true)
            }
            #expect(try await journal.finishHealthKitQuerySweep(plan, state: state))
            let before = try await journal.checkpoints(for: Self.sourceID)
            #expect(Set(before.compactMap(\.cursor)).count == 4)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let restored = try await reopened.healthKitQueryPlan(for: Self.sourceID, state: reopened.collectionState(), at: Fixture.date(200))
            #expect(restored.queries.count == 4)
            #expect(try await reopened.checkpoints(for: Self.sourceID) == before)
            #expect(try await reopened.sourceSetups().count == 1)
            await reopened.close()
        }
    }

    @Test
    func addingSleepCannotReuseHeartRateCoverageOrResetItsCursor() async throws {
        try await DeliveryFixture.withJournal(query: Fixture.definition()) { journal, _ in
            let heart = Fixture.plan(start: -600)
            let initial = try await Fixture.retain([heart], in: journal)
            let first = try await journal.healthKitQueryPlan(for: Self.sourceID, state: initial, at: Fixture.liveStart)
            for query in first.queries {
                _ = try await journal.stage(from: query.checkpoint, nextCursor: Data([9]), payloads: [], queryExhausted: true)
            }
            let both = try await Fixture.retain([heart, Self.sleepPlan(start: -600)], in: journal)
            let next = try await journal.healthKitQueryPlan(for: Self.sourceID, state: both, at: Fixture.date(200))
            let sleep = next.queries.filter { $0.definition.profile == .sleepStage }
            #expect(sleep.count == 2)
            #expect(sleep.allSatisfy { $0.checkpoint.cursor == nil })
            let history = try #require(sleep.first { $0.definition.kind == .historical })
            #expect(history.definition.start == Fixture.date(-600) && history.definition.end == Fixture.date(200))
            #expect(next.queries.filter { $0.definition.profile == .heartRate }.allSatisfy { $0.checkpoint.cursor == Data([9]) })
            #expect(try await journal.finishHealthKitQuerySweep(next, state: both) == false)
        }
    }

    @Test
    func sleepOnlyEnrollmentDoesNotRequireHeartRateAuthority() async throws {
        let definition = try HealthKitQueryDefinition(profile: .sleepStage, kind: .live, start: Fixture.liveStart).encoded()
        try await DeliveryFixture.withJournal(query: definition) { journal, _ in
            let state = try await Fixture.retain([Self.sleepPlan(start: -600)], in: journal)
            let plan = try await journal.healthKitQueryPlan(for: Self.sourceID, state: state, at: Fixture.liveStart)
            #expect(plan.queries.count == 2)
            #expect(plan.queries.allSatisfy { $0.definition.profile == .sleepStage })
            #expect(state.snapshot?.permitsHeartRateAcquisition == false)
            #expect(state.snapshot?.permitsSleepAcquisition == true)
        }
    }

    @Test
    func stoppingSleepDoesNotStopHeartRateOrResetSleepAnchors() async throws {
        try await DeliveryFixture.withJournal(query: Fixture.definition()) { journal, _ in
            let heart = Fixture.plan(), sleep = Self.sleepPlan(start: -600)
            let both = try await Fixture.retain([heart, sleep], in: journal)
            let first = try await journal.healthKitQueryPlan(for: Self.sourceID, state: both, at: Fixture.liveStart)
            for query in first.queries {
                _ = try await journal.stage(from: query.checkpoint, nextCursor: Data([1]), payloads: [], queryExhausted: true)
            }
            let before = try await journal.checkpoints(for: Self.sourceID)
            let stopped = try await journal.stopCollection(for: #require(UUID(uuidString: sleep.enrollmentId)))
            let next = try await journal.healthKitQueryPlan(for: Self.sourceID, state: stopped, at: Fixture.date(200))
            #expect(next.queries.count == 2)
            #expect(next.queries.allSatisfy { $0.definition.profile == .heartRate })
            let after = try await journal.checkpoints(for: Self.sourceID)
            #expect(after.map(\.queryID) == before.map(\.queryID))
            #expect(after.map(\.cursor) == before.map(\.cursor))
            #expect(after.map(\.queryDefinition) == before.map(\.queryDefinition))
        }
    }

    @Test
    func capacityFailureCannotReconcileOnlyOneMeasurement() async throws {
        try await DeliveryFixture.withJournal(limits: .init(maximumQueries: 3), query: Fixture.definition()) { journal, url in
            let state = try await Fixture.retain([Fixture.plan(), Self.sleepPlan(start: -600)], in: journal)
            let before = try await journal.checkpoints(for: Self.sourceID)
            await #expect(throws: DeliveryJournalError.capacityExceeded) {
                try await journal.healthKitQueryPlan(for: Self.sourceID, state: state, at: Fixture.liveStart)
            }
            #expect(try await journal.checkpoints(for: Self.sourceID) == before)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let retry = try await reopened.healthKitQueryPlan(for: Self.sourceID, state: reopened.collectionState(), at: Fixture.liveStart)
            #expect(retry.queries.count == 4)
            await reopened.close()
        }
    }
}


extension HealthKitQueryProfilesTests {
    private static func sleepPlan(start: Double) -> Components.Schemas.ParticipantCollectionPlan {
        var value = Fixture.plan(start: start)
        value.windows[0].requirements[0].profile = ParticipantCollectionSnapshot.sleepStageProfile
        return value
    }
}
