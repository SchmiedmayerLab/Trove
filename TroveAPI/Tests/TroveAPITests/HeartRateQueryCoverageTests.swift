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


struct HeartRateQueryCoverageTests {
    private typealias Fixture = HeartRatePlannerFixture

    @Test
    func adjacentAndOverlappingStudyWindowsProduceOneHistoricalQuery() async throws {
        try await DeliveryFixture.withJournal(query: Fixture.definition()) { journal, _ in
            let state = try await Fixture.retain([
                Fixture.plan(start: -90, end: -30), Fixture.plan(start: -60, end: 0), Fixture.plan(start: 0, end: 50)
            ], in: journal)
            let plan = try await journal.heartRateQueryPlan(for: DeliveryFixture.sourceID, state: state, at: Fixture.liveStart)
            #expect(Fixture.ranges(plan) == [Fixture.date(-90)..<Fixture.date(50)])
            #expect(plan.liveQuery == nil)
        }
    }

    @Test
    func broaderHistoryFillsBothSidesAndInteriorHolesWithoutReplacingExistingPredicates() async throws {
        try await DeliveryFixture.withJournal(query: Fixture.definition()) { journal, _ in
            let first = Fixture.plan(start: -60, end: -30), second = Fixture.plan(start: 0, end: 50)
            let state = try await Fixture.retain([first, second], in: journal)
            _ = try await journal.heartRateQueryPlan(for: DeliveryFixture.sourceID, state: state, at: Fixture.liveStart)
            let next = try await Fixture.retain([first, second, Fixture.plan(start: -90)], in: journal)
            let plan = try await journal.heartRateQueryPlan(for: DeliveryFixture.sourceID, state: next, at: Fixture.liveStart)
            #expect(Fixture.ranges(plan) == [
                Fixture.date(-90)..<Fixture.date(-60), Fixture.date(-60)..<Fixture.date(-30),
                Fixture.date(-30)..<Fixture.origin, Fixture.origin..<Fixture.date(50), Fixture.date(50)..<Fixture.liveStart
            ])
        }
    }

    @Test
    func futureOnlyRequirementDoesNotManufactureHistoricalWork() async throws {
        try await DeliveryFixture.withJournal(query: Fixture.definition()) { journal, _ in
            let state = try await Fixture.retain([Fixture.plan(start: 200)], in: journal)
            let plan = try await journal.heartRateQueryPlan(for: DeliveryFixture.sourceID, state: state, at: Fixture.liveStart)
            #expect(plan.queries.count == 1 && plan.liveQuery != nil)
            #expect(Fixture.ranges(plan).isEmpty)
        }
    }

    @Test
    func backwardsClockCannotLeaveAGapBeforeTheFixedLiveBoundary() async throws {
        try await DeliveryFixture.withJournal(query: Fixture.definition()) { journal, _ in
            let original = Fixture.plan(start: 200)
            let state = try await Fixture.retain([original], in: journal)
            _ = try await journal.heartRateQueryPlan(for: DeliveryFixture.sourceID, state: state, at: Fixture.liveStart)
            let adopted = Fixture.adopt(original, at: 300, start: -60)
            let next = try await Fixture.retain([adopted], in: journal)
            let plan = try await journal.heartRateQueryPlan(for: DeliveryFixture.sourceID, state: next, at: Fixture.date(50))
            #expect(Fixture.ranges(plan) == [Fixture.date(-60)..<Fixture.liveStart])
        }
    }
}
