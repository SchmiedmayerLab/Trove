//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

#if canImport(HealthKit)

import CoreLocation
import Foundation
import GroveFHIRContract
import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit
import Testing
@testable import TroveAPIClient
@testable import TroveHealthKit


struct HealthKitRetractionMaintenanceTests {
    private typealias Fixture = HeartRatePlannerFixture

    private struct Collected: Sendable {
        let route: HKWorkoutRoute
        let plan: Components.Schemas.ParticipantCollectionPlan
        let original: Data
    }

    @Test
    func disabledCollectionRetractsOnlyKnownRecordsAfterPruningAndReopening() async throws {
        try await Self.withCollectedRoute { journal, url, collected in
            _ = try await Fixture.retain([Fixture.adopt(collected.plan, at: 200, start: nil)], in: journal)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            do {
                try await Self.verifyMaintenance(reopened, collected: collected)
            } catch {
                await reopened.close()
                throw error
            }
            await reopened.close()
        }
    }

    @Test
    func collectedSampleAbsentFromALaterPageIsNotRetracted() async throws {
        try await Self.withCollectedRoute { journal, _, _ in
            let pending = try await journal.pendingDeliveryIDs()
            let acquisition = try HealthKitAcquisition(journal: journal, scope: DeliveryFixture.scope) {}
            // HealthKit reports neither the route nor a deletion, as on a phone that never received the sample.
            let page = try await acquisition.collect(
                localID: DeliveryFixture.epoch,
                application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
                host: .init(operatingSystemVersion: "27.2")
            ) { _, _ in .init(added: [], deletedIDs: [], nextAnchor: QueryAnchor(HKQueryAnchor(fromValue: 2))) }
            #expect(page.eventIDs.isEmpty && page.isCaughtUp)
            #expect(try await journal.pendingDeliveryIDs() == pending)
        }
    }

    @Test
    func withdrawalDuringMaintenancePreventsRetractionAndCursorAdvance() async throws {
        try await Self.withCollectedRoute { journal, _, collected in
            _ = try await Fixture.retain([Fixture.adopt(collected.plan, at: 200, start: nil)], in: journal)
            let before = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let enrollment = try #require(UUID(uuidString: collected.plan.enrollmentId))
            let acquisition = try HealthKitAcquisition(journal: journal, scope: DeliveryFixture.scope) {}
            await #expect(throws: DeliveryJournalError.staleCheckpoint) {
                try await acquisition.collect(
                    localID: DeliveryFixture.epoch,
                    application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
                    host: .init(operatingSystemVersion: "27.2")
                ) { _, _ in
                    _ = try await journal.stopCollection(for: enrollment)
                    return .init(added: [], deletedIDs: [collected.route.uuid], nextAnchor: QueryAnchor(HKQueryAnchor(fromValue: 2)))
                }
            }
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID).cursor == before.cursor)
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
            await #expect(throws: ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized) {
                try await journal.healthKitQueryPlan(for: DeliveryFixture.sourceID, state: journal.collectionState())
            }
        }
    }
}


extension HealthKitRetractionMaintenanceTests {
    private static func verifyMaintenance(_ journal: EventDeliveryJournal, collected: Collected) async throws {
        let state = try await journal.collectionState()
        #expect(state.snapshot?.acquisitionStreams.isEmpty == true)
        let plan = try await journal.healthKitQueryPlan(for: DeliveryFixture.sourceID, state: state, at: Fixture.date(250))
        #expect(plan.queries.count == 1 && plan.queries.first?.mode == .retractionsOnly)
        #expect(plan.liveQueries.isEmpty)
        let added = try WorkoutRouteFixture.sample(start: Fixture.date(250), end: Fixture.date(300), count: 1)
        let delta = HealthKitAcquisition.Delta(
            added: [added], deletedIDs: [collected.route.uuid, UUID()], nextAnchor: QueryAnchor(HKQueryAnchor(fromValue: 2))
        ) { _ in
            Issue.record("Disabled collection must not read new locations")
            throw HealthKitAcquisition.AcquisitionError.unsupportedDelta
        }
        let page = try await collect(delta, journal: journal)
        #expect(page.changeCount == 3 && !page.isCaughtUp && page.eventIDs.count == 1)
        let id = try #require(page.eventIDs.first)
        let attempt = try #require(try await journal.prepareAttempt(id))
        let retraction = try ExchangeRecord(validating: attempt.bytes)
        let original = try ExchangeRecord(validating: collected.original)
        #expect(retraction.kind == .retraction && retraction.sourceRecord == original.sourceRecord)
        #expect(retraction.outputFullURLs.isEmpty && attempt.commitment.targetIntent.targets.isEmpty)
        let cursor = try await #require(journal.checkpoint(for: DeliveryFixture.sourceID).cursor)
        #expect(try JSONDecoder().decode(QueryAnchor.self, from: cursor) == delta.nextAnchor)
    }

    private static func collect(_ delta: HealthKitAcquisition.Delta, journal: EventDeliveryJournal) async throws -> HealthKitAcquisition.Page {
        let acquisition = try HealthKitAcquisition(journal: journal, scope: DeliveryFixture.scope) {}
        return try await acquisition.collect(
            localID: DeliveryFixture.epoch,
            application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
            host: .init(operatingSystemVersion: "27.2")
        ) { _, _ in delta }
    }

    private static func withCollectedRoute(_ operation: (EventDeliveryJournal, URL, Collected) async throws -> Void) async throws {
        let definition = try HealthKitQueryDefinition(stream: .workoutRoute, kind: .live, start: Fixture.date(50))
        try await DeliveryFixture.withJournal(query: definition.encoded()) { journal, url in
            var plan = Fixture.plan(start: 0)
            plan.windows[0].requirements[0].profile = CollectionObservationProfile.workout.rawValue
            plan.windows[0].requirements[0].includeWorkoutRoutes = true
            _ = try await Fixture.retain([plan], in: journal)
            let route = try WorkoutRouteFixture.sample(start: Fixture.date(25), end: Fixture.date(150), count: 1)
            let page = try await collect(
                .init(added: [route], deletedIDs: [], nextAnchor: QueryAnchor(HKQueryAnchor(fromValue: 1)), readRoute: { route in
                    let locations = AsyncThrowingStream<CLLocation, any Error> { continuation in
                        continuation.yield(WorkoutRouteFixture.location(at: Fixture.date(75)))
                        continuation.finish()
                    }
                    return try await HealthKitRecordingFile.workoutRoute(
                        route, locations: locations, relativePath: "recordings/route.csv", maximumByteCount: 4096
                    )
                }),
                journal: journal
            )
            let id = try #require(page.eventIDs.first)
            let attempt = try #require(try await journal.prepareAttempt(id))
            try await journal.recordReceipt(DeliveryFixture.receipt(attempt), for: id)
            #expect(try await journal.reclaimRecordingFiles() == 1)
            #expect(try await journal.pruneDelivered() == 1)
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
            try await operation(journal, url, Collected(route: route, plan: plan, original: attempt.bytes))
        }
    }
}

#endif
