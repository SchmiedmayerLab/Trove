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


struct HeartRateQueryPlanTests {
    private typealias Fixture = HeartRatePlannerFixture
    private static let sourceID = DeliveryFixture.sourceID

    @Test
    func initialHistoryUsesFixedLiveSplitAndRestoresWithoutCreatingMoreQueries() async throws {
        try await DeliveryFixture.withJournal(query: Fixture.definition()) { journal, url in
            let state = try await Fixture.retain([Fixture.plan()], in: journal)
            let plan = try await journal.heartRateQueryPlan(for: Self.sourceID, state: state, at: Fixture.date(150))
            #expect(Fixture.ranges(plan) == [Fixture.date(-600)..<Fixture.liveStart])
            #expect(plan.liveQuery?.definition.start == Fixture.liveStart)
            let history = try #require(plan.queries.first { $0.definition.kind == .historical })
            _ = try await journal.stage(from: history.checkpoint, nextCursor: Data([1]), payloads: [])
            let before = try await journal.checkpoints(for: Self.sourceID)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let restored = try await reopened.heartRateQueryPlan(for: Self.sourceID, state: reopened.collectionState(), at: Fixture.date(200))
            #expect(restored.queries.count == 2)
            #expect(try await reopened.checkpoints(for: Self.sourceID) == before)
            #expect(restored.sweepStart == plan.sweepStart)
            #expect(try await reopened.sourceSetups().count == 1)
            await reopened.close()
        }
    }

    @Test
    func broaderAdoptionAddsOnlyMissingHistoryWithoutResettingEitherCursor() async throws {
        try await DeliveryFixture.withJournal(query: Fixture.definition()) { journal, _ in
            let original = Fixture.plan(start: 0)
            let state = try await Fixture.retain([original], in: journal)
            let plan = try await journal.heartRateQueryPlan(for: Self.sourceID, state: state, at: Fixture.liveStart)
            for query in plan.queries {
                _ = try await journal.stage(from: query.checkpoint, nextCursor: Data([7]), payloads: [], queryExhausted: true)
            }
            let adopted = Fixture.adopt(original, at: 200, start: -600)
            let next = try await Fixture.retain([adopted], in: journal)
            let broader = try await journal.heartRateQueryPlan(for: Self.sourceID, state: next, at: Fixture.date(200))
            #expect(Fixture.ranges(broader) == [Fixture.date(-600)..<Fixture.origin, Fixture.origin..<Fixture.liveStart])
            let oldIDs = Set(plan.queries.map { $0.checkpoint.queryID })
            #expect(broader.queries.filter { oldIDs.contains($0.checkpoint.queryID) }.allSatisfy { $0.checkpoint.cursor == Data([7]) })
        }
    }

    @Test
    func previouslySkippedGapGetsFreshBackfillEvenInsideExistingLivePredicate() async throws {
        try await DeliveryFixture.withJournal(query: Fixture.definition()) { journal, _ in
            let original = Fixture.plan(start: 0)
            let state = try await Fixture.retain([original], in: journal)
            let plan = try await journal.heartRateQueryPlan(for: Self.sourceID, state: state, at: Fixture.liveStart)
            let live = try #require(plan.liveQuery)
            _ = try await journal.stage(from: live.checkpoint, nextCursor: Data([1]), payloads: [], queryExhausted: true)
            let withoutHeartRate = Fixture.adopt(original, at: 200, start: nil)
            let restored = Fixture.adopt(withoutHeartRate, at: 400, start: 0)
            let adopted = try await Fixture.retain([restored], in: journal)
            let updated = try await journal.heartRateQueryPlan(for: Self.sourceID, state: adopted, at: Fixture.date(450))
            #expect(Fixture.ranges(updated) == [Fixture.origin..<Fixture.liveStart, Fixture.date(200)..<Fixture.date(450)])
            #expect(updated.liveQuery?.checkpoint.cursor == Data([1]))
        }
    }

    @Test
    func secondStudyReusesCoveredHistoryAndItsConsentIsRememberedWithoutAnotherQuery() async throws {
        try await DeliveryFixture.withJournal(query: Fixture.definition()) { journal, _ in
            let first = Fixture.plan(), second = Fixture.plan()
            let state = try await Fixture.retain([first], in: journal)
            let original = try await journal.heartRateQueryPlan(for: Self.sourceID, state: state, at: Fixture.liveStart)
            let both = try await Fixture.retain([first, second], in: journal)
            let shared = try await journal.heartRateQueryPlan(for: Self.sourceID, state: both, at: Fixture.date(200))
            #expect(shared.queries.map { $0.checkpoint.queryID } == original.queries.map { $0.checkpoint.queryID })
            let stopped = try await journal.stopCollection(for: #require(UUID(uuidString: first.enrollmentId)))
            let remaining = try await journal.heartRateQueryPlan(for: Self.sourceID, state: stopped, at: Fixture.date(300))
            #expect(remaining.queries.count == 2)
            #expect(Fixture.ranges(remaining) == Fixture.ranges(original))
        }
    }

    @Test
    func capacityFailureRollsBackEveryNewQueryAndConsentMarker() async throws {
        try await DeliveryFixture.withJournal(limits: .init(maximumQueries: 2), query: Fixture.definition()) { journal, url in
            let state = try await Fixture.retain([Fixture.plan(start: -60, end: -30), Fixture.plan(start: 0, end: 50)], in: journal)
            let before = try await journal.checkpoints(for: Self.sourceID)
            await #expect(throws: DeliveryJournalError.capacityExceeded) {
                try await journal.heartRateQueryPlan(for: Self.sourceID, state: state, at: Fixture.liveStart)
            }
            #expect(try await journal.checkpoints(for: Self.sourceID) == before)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let retry = try await reopened.heartRateQueryPlan(for: Self.sourceID, state: reopened.collectionState(), at: Fixture.liveStart)
            #expect(Fixture.ranges(retry) == [Fixture.date(-60)..<Fixture.date(-30), Fixture.origin..<Fixture.date(50)])
            await reopened.close()
        }
    }

    @Test
    func localWithdrawalRejectsCapturedPlanWithoutCreatingQueriesOrAdvancingCursors() async throws {
        try await DeliveryFixture.withJournal(query: Fixture.definition()) { journal, _ in
            let enrollment = Fixture.plan()
            let state = try await Fixture.retain([enrollment], in: journal)
            _ = try await journal.stopCollection(for: #require(UUID(uuidString: enrollment.enrollmentId)))
            let before = try await journal.checkpoints(for: Self.sourceID)
            await #expect(throws: DeliveryJournalError.staleCollectionState) {
                try await journal.heartRateQueryPlan(for: Self.sourceID, state: state, at: Fixture.liveStart)
            }
            #expect(try await journal.checkpoints(for: Self.sourceID) == before)
        }
    }

    @Test
    func filteredPageWithNoPayloadsDoesNotCompleteItsQuery() async throws {
        try await DeliveryFixture.withJournal(query: Fixture.definition()) { journal, _ in
            let state = try await Fixture.retain([Fixture.plan(start: 100)], in: journal)
            let plan = try await journal.heartRateQueryPlan(for: Self.sourceID, state: state, at: Fixture.liveStart)
            let live = try #require(plan.liveQuery)
            _ = try await journal.stage(from: live.checkpoint, nextCursor: Data([1]), payloads: [])
            #expect(try await journal.finishHeartRateQuerySweep(plan, state: state) == false)
            let current = try await journal.checkpoint(for: Self.sourceID)
            _ = try await journal.stage(from: current, nextCursor: Data([2]), payloads: [], queryExhausted: true)
            #expect(try await journal.finishHeartRateQuerySweep(plan, state: state))
            let next = try await journal.heartRateQueryPlan(for: Self.sourceID, state: state, at: Fixture.date(200))
            #expect(next.pendingQueries.count == 1)
        }
    }
}
