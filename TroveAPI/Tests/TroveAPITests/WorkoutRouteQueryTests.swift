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


struct WorkoutRouteQueryTests {
    private typealias Fixture = HeartRatePlannerFixture
    private static let sourceID = DeliveryFixture.sourceID

    @Test
    func enablingRoutesBackfillsWithoutReusingWorkoutCoverage() async throws {
        let definition = try HealthKitQueryDefinition(profile: .workout, kind: .live, start: Fixture.liveStart).encoded()
        try await DeliveryFixture.withJournal(query: definition) { journal, url in
            let workout = Self.plan(routes: false)
            let before = try await Fixture.retain([workout], in: journal)
            let first = try await journal.healthKitQueryPlan(for: Self.sourceID, state: before, at: Fixture.liveStart)
            #expect(first.queries.count == 2)
            for query in first.queries {
                _ = try await journal.stage(from: query.checkpoint, nextCursor: Data([9]), payloads: [], queryExhausted: true)
            }
            let adopted = Self.adopt(workout, at: 200, routes: true)
            let state = try await Fixture.retain([adopted], in: journal)
            let next = try await journal.healthKitQueryPlan(for: Self.sourceID, state: state, at: Fixture.date(200))
            let routes = next.queries.filter { $0.definition.stream == .workoutRoute }
            #expect(routes.count == 2)
            #expect(routes.allSatisfy { $0.checkpoint.cursor == nil })
            #expect(next.queries.filter { $0.definition.stream == .workout }.allSatisfy { $0.checkpoint.cursor == Data([9]) })
            let history = try #require(routes.first { $0.definition.kind == .historical })
            #expect(history.definition.start == Fixture.date(-600) && history.definition.end == Fixture.date(200))
            #expect(state.snapshot?.acquisitionProfiles == [.workout])
            #expect(state.snapshot?.acquisitionStreams == [.workout, .workoutRoute])
            #expect(try await journal.finishHealthKitQuerySweep(next, state: state) == false)
            let checkpoints = try await journal.checkpoints(for: Self.sourceID)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let restored = try await reopened.healthKitQueryPlan(for: Self.sourceID, state: reopened.collectionState(), at: Fixture.date(210))
            #expect(restored.queries.count == 4)
            #expect(try await reopened.checkpoints(for: Self.sourceID) == checkpoints)
            await reopened.close()
        }
    }

    @Test
    func disablingRoutesRetainsTheirAnchorsAndReenablingBackfillsTheGap() async throws {
        let definition = try HealthKitQueryDefinition(profile: .workout, kind: .live, start: Fixture.liveStart).encoded()
        try await DeliveryFixture.withJournal(query: definition) { journal, _ in
            let enabled = Self.plan(routes: true)
            let state = try await Fixture.retain([enabled], in: journal)
            let first = try await journal.healthKitQueryPlan(for: Self.sourceID, state: state, at: Fixture.liveStart)
            for query in first.queries {
                _ = try await journal.stage(from: query.checkpoint, nextCursor: Data([7]), payloads: [], queryExhausted: true)
            }
            let saved = try await journal.checkpoints(for: Self.sourceID)
            let disabled = Self.adopt(enabled, at: 200, routes: false)
            let stopped = try await Fixture.retain([disabled], in: journal)
            let withoutRoutes = try await journal.healthKitQueryPlan(for: Self.sourceID, state: stopped, at: Fixture.date(200))
            #expect(withoutRoutes.queries.count == 4)
            #expect(withoutRoutes.queries.filter { $0.definition.stream == .workoutRoute }.allSatisfy { $0.mode == .retractionsOnly })
            #expect(withoutRoutes.liveQueries.allSatisfy { $0.definition.stream == .workout })
            #expect(try await journal.checkpoints(for: Self.sourceID).map(\.cursor) == saved.map(\.cursor))
            let resumed = try await Fixture.retain([Self.adopt(disabled, at: 300, routes: true)], in: journal)
            let plan = try await journal.healthKitQueryPlan(for: Self.sourceID, state: resumed, at: Fixture.date(300))
            let routes = plan.queries.filter { $0.definition.stream == .workoutRoute }
            #expect(routes.count == 3)
            let newHistory = try #require(routes.first { $0.checkpoint.cursor == nil })
            #expect(newHistory.definition.start == Fixture.date(200))
            #expect(newHistory.definition.end == Fixture.date(300))
            #expect(routes.filter { $0.checkpoint.cursor != nil }.allSatisfy { $0.checkpoint.cursor == Data([7]) })
        }
    }

    @Test
    func routeDefinitionsAreDistinctAndKeepWholeOverlappingRecords() throws {
        let start = Fixture.date(0), end = Fixture.date(60)
        let route = try HealthKitQueryDefinition(stream: .workoutRoute, kind: .historical, start: start, end: end)
        let workout = try HealthKitQueryDefinition(profile: .workout, kind: .historical, start: start, end: end)
        #expect(try route.encoded() != workout.encoded())
        #expect(try HealthKitQueryDefinition(bytes: route.encoded()) == route)
        #expect(route.contains(Fixture.date(-10), ending: Fixture.date(70)))
        #expect(!route.contains(Fixture.date(-10), ending: start))
        #expect(!route.contains(end, ending: Fixture.date(70)))
    }

    @Test
    func neverStartedRoutesAreNotQueriedAfterDisablingAndEnrollmentEndStopsMaintenance() async throws {
        let definition = try HealthKitQueryDefinition(profile: .workout, kind: .live, start: Fixture.liveStart).encoded()
        try await DeliveryFixture.withJournal(query: definition) { journal, _ in
            var enabled = Self.plan(routes: true)
            enabled.endsAt = Fixture.date(300)
            enabled.windows[0].end = enabled.endsAt
            enabled.windows[0].requirements[0].end = enabled.endsAt
            let state = try await Fixture.retain([enabled], in: journal)
            let initial = try await journal.healthKitQueryPlan(for: Self.sourceID, state: state, at: Fixture.liveStart)
            for query in initial.queries where query.definition.stream == .workout {
                _ = try await journal.stage(from: query.checkpoint, nextCursor: Data([1]), payloads: [])
            }
            var disabled = Fixture.adopt(enabled, at: 200, start: nil)
            disabled.windows[1].end = disabled.endsAt
            let stopped = try await Fixture.retain([disabled], in: journal)
            let maintenance = try await journal.healthKitQueryPlan(for: Self.sourceID, state: stopped, at: Fixture.date(299))
            #expect(maintenance.queries.count == 2 && maintenance.queries.allSatisfy { $0.mode == .retractionsOnly })
            #expect(maintenance.queries.allSatisfy { $0.definition.stream == .workout })
            #expect(maintenance.liveQueries.isEmpty)
            await #expect(throws: ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized) {
                try await journal.healthKitQueryPlan(for: Self.sourceID, state: stopped, at: Fixture.date(300))
            }
        }
    }
}


extension WorkoutRouteQueryTests {
    private static func plan(routes: Bool) -> Components.Schemas.ParticipantCollectionPlan {
        var value = Fixture.plan()
        value.windows[0].requirements[0].profile = CollectionObservationProfile.workout.rawValue
        value.windows[0].requirements[0].includeWorkoutRoutes = routes
        return value
    }

    private static func adopt(
        _ plan: Components.Schemas.ParticipantCollectionPlan, at offset: Double, routes: Bool
    ) -> Components.Schemas.ParticipantCollectionPlan {
        var value = Fixture.adopt(plan, at: offset, start: -600)
        let index = value.windows.count - 1
        value.windows[index].requirements[0].profile = CollectionObservationProfile.workout.rawValue
        value.windows[index].requirements[0].includeWorkoutRoutes = routes
        return value
    }
}
