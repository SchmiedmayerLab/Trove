// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import TroveAPIClient


struct BodyWeightQueryTests {
    private typealias Fixture = HeartRatePlannerFixture

    private static func plan() -> Components.Schemas.ParticipantCollectionPlan {
        var value = Fixture.plan(start: -600)
        value.windows[0].requirements[0].profile = CollectionObservationProfile.bodyWeight.rawValue
        return value
    }

    @Test
    func pointBoundsAndExistingQueryEncodingRemainUnchanged() throws {
        let start = Fixture.date(50), end = Fixture.date(100)
        let bodyWeight = try HealthKitQueryDefinition(profile: .bodyWeight, kind: .historical, start: start, end: end)
        #expect(!CollectionObservationProfile.bodyWeight.isInterval)
        #expect(bodyWeight.contains(start) && !bodyWeight.contains(end))
        #expect(!bodyWeight.contains(start.addingTimeInterval(-1)))
        #expect(!bodyWeight.contains(start, ending: end))
        #expect(try HealthKitQueryDefinition(bytes: bodyWeight.encoded()) == bodyWeight)
        let original = Data("{\"adapter\":\"healthkit\",\"kind\":\"live\",\"start\":-978307200,\"stream\":\"heartRate\",\"version\":6}".utf8)
        #expect(try HealthKitQueryDefinition(bytes: original).encoded() == original)
    }

    @Test
    func bodyWeightAddsIndependentQueriesAndSurvivesOfflineReopenWithoutHeartRatePermission() async throws {
        let initial = try HealthKitQueryDefinition(profile: .bodyWeight, kind: .live, start: Fixture.liveStart).encoded()
        try await DeliveryFixture.withJournal(query: initial) { journal, url in
            let weight = Self.plan()
            let state = try await Fixture.retain([weight], in: journal)
            let queries = try await journal.healthKitQueryPlan(for: DeliveryFixture.sourceID, state: state, at: Fixture.liveStart)
            #expect(queries.queries.count == 2)
            #expect(queries.queries.allSatisfy { $0.definition.profile == .bodyWeight })
            #expect(state.snapshot?.permitsAcquisition(of: .heartRate) == false)
            for query in queries.queries {
                _ = try await journal.stage(from: query.checkpoint, nextCursor: Data([9]), payloads: [], queryExhausted: true)
            }
            let before = try await journal.checkpoints(for: DeliveryFixture.sourceID)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            do {
                #expect(try await reopened.checkpoints(for: DeliveryFixture.sourceID) == before)
                let mixed = try await Fixture.retain([weight, Fixture.plan()], in: reopened)
                let added = try await reopened.healthKitQueryPlan(for: DeliveryFixture.sourceID, state: mixed, at: Fixture.liveStart)
                #expect(added.queries.filter { $0.definition.profile == .bodyWeight }.allSatisfy { $0.checkpoint.cursor == Data([9]) })
                #expect(added.queries.filter { $0.definition.profile == .heartRate }.allSatisfy { $0.checkpoint.cursor == nil })
                let stopped = try await reopened.stopCollection(for: #require(UUID(uuidString: weight.enrollmentId)))
                let active = try #require(stopped.snapshot).active(at: Fixture.liveStart)
                #expect(!active.permitsAcquisition(of: .bodyWeight) && active.permitsAcquisition(of: .heartRate))
            } catch {
                await reopened.close()
                throw error
            }
            await reopened.close()
        }
    }

    @Test
    func heartRateOnlyScopeDoesNotSelectBodyWeightOrItsRoutes() throws {
        let heart = Fixture.plan()
        let snapshot = try ParticipantCollectionSnapshot(plans: [heart], enrollmentIDs: [#require(UUID(uuidString: heart.enrollmentId))])
        #expect(try snapshot.consentIDs(profile: .bodyWeight, start: Fixture.liveStart, end: nil).isEmpty)
        #expect(!snapshot.permitsAcquisition(of: .bodyWeight))
        #expect(throws: ParticipantCollectionSnapshot.CollectionError.invalidPlan) {
            try snapshot.consentIDs(profile: .bodyWeight, start: Fixture.liveStart, end: nil, requiresWorkoutRoute: true)
        }
    }
}
