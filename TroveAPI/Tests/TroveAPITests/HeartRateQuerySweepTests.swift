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


struct HeartRateQuerySweepTests {
    private typealias Fixture = HeartRatePlannerFixture
    private static let sourceID = DeliveryFixture.sourceID

    @Test
    func moreThanOnePassOfHistoryRemainsFairAcrossRefreshesAndRestart() async throws {
        try await DeliveryFixture.withJournal(query: Fixture.definition()) { journal, url in
            let enrollments = (0..<12).map { Fixture.plan(start: Double($0 * 6), end: Double($0 * 6 + 3)) }
            let state = try await Fixture.retain(enrollments, in: journal)
            let plan = try await journal.heartRateQueryPlan(for: Self.sourceID, state: state, at: Fixture.liveStart)
            #expect(plan.liveQuery == nil && plan.pendingQueries.count == 12)
            let visited = try await Self.visit(8, in: journal, state: state)
            #expect(try await journal.finishHeartRateQuerySweep(plan, state: state) == false)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            // Observation-only refreshes change the journal authority token, but not the active sweep.
            let refreshed = enrollments.map { original in var value = original; value.asOf += 1; return value }
            let nextState = try await Fixture.retain(refreshed, in: reopened)
            let continued = try await reopened.heartRateQueryPlan(for: Self.sourceID, state: nextState, at: Fixture.date(200))
            #expect(continued.sweepStart == plan.sweepStart && continued.pendingQueries.count == 4)
            #expect(Set(continued.pendingQueries.map { $0.checkpoint.queryID }).isDisjoint(with: visited))
            let remainder = try await Self.visit(4, in: reopened, state: nextState)
            #expect(visited.union(remainder).count == 12)
            #expect(try await reopened.finishHeartRateQuerySweep(continued, state: nextState))
            let nextSweep = try await reopened.heartRateQueryPlan(for: Self.sourceID, state: nextState, at: Fixture.date(300))
            #expect(nextSweep.pendingQueries.count == 12)
            await reopened.close()
        }
    }

    @Test
    func aNewQueryCannotBeOmittedWhenCompletingAnOlderPlan() async throws {
        try await DeliveryFixture.withJournal(query: Fixture.definition()) { journal, _ in
            let state = try await Fixture.retain([Fixture.plan(start: 100)], in: journal)
            let plan = try await journal.heartRateQueryPlan(for: Self.sourceID, state: state, at: Fixture.liveStart)
            let live = try #require(plan.liveQuery)
            _ = try await journal.stage(from: live.checkpoint, nextCursor: Data([1]), payloads: [], queryExhausted: true)
            let definition = try HeartRateQueryDefinition(kind: .historical, start: Fixture.date(100), end: Fixture.date(120))
            _ = try await journal.createQuery(for: Self.sourceID, queryID: UUID(), definition: definition.encoded())
            #expect(try await journal.finishHeartRateQuerySweep(plan, state: state) == false)
        }
    }

    @Test(arguments: ["duplicate-consents", "malformed-consents", "sequence-exhausted"])
    func corruptPlanningStateNeverResetsQueriesOrLosesQueuedBytes(failure: String) async throws {
        try await DeliveryFixture.withJournal(query: Fixture.definition()) { journal, url in
            let state = try await Fixture.retain([Fixture.plan()], in: journal)
            _ = try await journal.heartRateQueryPlan(for: Self.sourceID, state: state, at: Fixture.liveStart)
            let connection = try DeliverySQLite(url: url)
            defer { connection.close() }
            if failure == "sequence-exhausted" {
                try connection.execute("UPDATE acquisition_query SET last_served = ?", [.integer(Int64.max)])
                let checkpoint = try await journal.checkpoint(for: Self.sourceID)
                await #expect(throws: DeliveryJournalError.capacityExceeded) {
                    try await journal.stage(
                        from: checkpoint, nextCursor: Data([1]), payloads: [DeliveryFixture.payload(sequence: 1, changes: ["rollback"])]
                    )
                }
                #expect(try await journal.pendingDeliveryIDs().isEmpty)
                #expect(try await journal.checkpoint(for: Self.sourceID) == checkpoint)
            } else {
                let id = UUID()
                let bytes = try failure == "duplicate-consents" ? JSONEncoder().encode([id, id]) : Data([0])
                try connection.execute("UPDATE source_state SET collection_consents = ?", [.blob(bytes)])
                let before = try await journal.checkpoints(for: Self.sourceID)
                await #expect(throws: DeliveryJournalError.corruptJournal) {
                    try await journal.heartRateQueryPlan(for: Self.sourceID, state: state, at: Fixture.liveStart)
                }
                #expect(try await journal.checkpoints(for: Self.sourceID) == before)
            }
        }
    }

    @Test
    func freshAuthorityCannotBeSubstitutedWhenCompletingAnOldPlan() async throws {
        try await DeliveryFixture.withJournal(query: Fixture.definition()) { journal, _ in
            let original = Fixture.plan(start: 100)
            let state = try await Fixture.retain([original], in: journal)
            let plan = try await journal.heartRateQueryPlan(for: Self.sourceID, state: state, at: Fixture.liveStart)
            let live = try #require(plan.liveQuery)
            _ = try await journal.stage(from: live.checkpoint, nextCursor: Data([1]), payloads: [], queryExhausted: true)
            let next = try await Fixture.retain([Fixture.adopt(original, at: 200, start: -600)], in: journal)
            await #expect(throws: DeliveryJournalError.staleCollectionState) {
                try await journal.finishHeartRateQuerySweep(plan, state: next)
            }
            let updated = try await journal.heartRateQueryPlan(for: Self.sourceID, state: next, at: Fixture.date(200))
            #expect(Fixture.ranges(updated) == [Fixture.date(-600)..<Fixture.liveStart])
        }
    }
}


extension HeartRateQuerySweepTests {
    private static func visit(
        _ count: Int, in journal: EventDeliveryJournal, state: ParticipantCollectionState
    ) async throws -> Set<UUID> {
        var visited: Set<UUID> = []
        for _ in 0..<count {
            let plan = try await journal.heartRateQueryPlan(for: sourceID, state: state, at: Fixture.date(200))
            let next = try #require(plan.pendingQueries.first)
            #expect(visited.insert(next.checkpoint.queryID).inserted)
            _ = try await journal.stage(from: next.checkpoint, nextCursor: Data([1]), payloads: [], queryExhausted: true)
        }
        return visited
    }
}
