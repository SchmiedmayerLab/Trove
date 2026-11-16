// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import TroveAPIClient


struct HealthKitQueryVersionTransitionTests {
    private typealias Fixture = HeartRatePlannerFixture

    @Test
    func dualShapeVersionAddsWholeOverlapWithoutReinterpretingVersionSix() throws {
        let current = try HealthKitQueryDefinition(profile: .heartRate, kind: .historical, start: Fixture.date(50), end: Fixture.date(100))
        let currentText = String(decoding: try current.encoded(), as: UTF8.self)
        let legacyBytes = Data(currentText.replacingOccurrences(of: "\"version\":7", with: "\"version\":6").utf8)
        let legacy = try HealthKitQueryDefinition(bytes: legacyBytes)
        #expect(current.version == 7 && legacy.version == 6)
        #expect(try legacy.encoded() == legacyBytes)
        #expect(current.contains(Fixture.date(40), ending: Fixture.date(60)))
        #expect(!legacy.contains(Fixture.date(40), ending: Fixture.date(60)))
        #expect(!current.contains(Fixture.date(40), ending: Fixture.date(50)))
        #expect(!current.contains(Fixture.date(100), ending: Fixture.date(110)))
        #expect(current.contains(Fixture.date(50)) && current.contains(Fixture.date(50), ending: Fixture.date(50)))
        #expect(!current.contains(Fixture.date(100)))
    }

    @Test
    func transitionCreatesReplayQueriesAndKeepsTheOldCursorAndPendingWorkAcrossReopen() async throws {
        let latest = try Fixture.definition()
        let legacy = Data(String(decoding: latest, as: UTF8.self).replacingOccurrences(of: "\"version\":7", with: "\"version\":6").utf8)
        try await DeliveryFixture.withJournal(query: legacy) { journal, url in
            let pending = try #require(await DeliveryFixture.stage(journal, changes: ["retained-before-transition"]).first)
            let previous = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let state = try await Fixture.retain([Fixture.plan(start: -600)], in: journal)
            let plan = try await journal.healthKitQueryPlan(for: DeliveryFixture.sourceID, state: state, at: Fixture.liveStart)
            #expect(plan.queries.count == 2 && plan.queries.allSatisfy { $0.definition.version == 7 })
            #expect(plan.queries.allSatisfy { $0.checkpoint.cursor == nil && $0.checkpoint.queryID != previous.queryID })
            let stored = try await journal.checkpoints(for: DeliveryFixture.sourceID)
            let preserved = try #require(stored.first { $0.queryID == previous.queryID })
            #expect(stored.count == 3 && preserved.queryDefinition == legacy && preserved.cursor == previous.cursor)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            do {
                let state = try await reopened.collectionState()
                let repeated = try await reopened.healthKitQueryPlan(for: DeliveryFixture.sourceID, state: state, at: Fixture.liveStart)
                #expect(Set(repeated.queries.map { $0.checkpoint.queryID }) == Set(plan.queries.map { $0.checkpoint.queryID }))
                #expect(try await reopened.checkpoints(for: DeliveryFixture.sourceID).count == 3)
                #expect(try await reopened.prepareAttempt(pending) != nil)
            } catch {
                await reopened.close()
                throw error
            }
            await reopened.close()
        }
    }
}
