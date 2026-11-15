//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

#if canImport(HealthKit)

import Foundation
import GroveHealthKit
import HealthKit
import Testing
@testable import TroveAPIClient
@testable import TroveHealthKit


struct HeartRateQuerySchedulingTests {
    private actor Queries {
        private(set) var kinds: [HealthKitQueryDefinition.Kind] = []
        private var historyPages = 0

        func page(_ definition: HealthKitQueryDefinition, anchor: QueryAnchor) -> HealthKitAcquisition.Delta {
            kinds.append(definition.kind)
            guard definition.kind == .historical else {
                return .init(added: [], deletedIDs: [], nextAnchor: QueryAnchor(HKQueryAnchor(fromValue: 1)))
            }
            historyPages += 1
            #expect(anchor == (historyPages == 1 ? QueryAnchor() : QueryAnchor(HKQueryAnchor(fromValue: historyPages - 1))))
            // Exercise a filtered, nonempty page. No payloads does not mean the anchored query is exhausted.
            let outside = HKQuantitySample(
                type: HKQuantityType(.heartRate),
                quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: 72),
                start: HeartRatePlannerFixture.date(500),
                end: HeartRatePlannerFixture.date(501)
            )
            return .init(added: [outside], deletedIDs: [], nextAnchor: QueryAnchor(HKQueryAnchor(fromValue: historyPages)))
        }
    }

    @Test
    func eachBoundedPassServicesLiveDataAndResumesHistoryAfterRestart() async throws {
        try await DeliveryFixture.withJournal(query: HeartRatePlannerFixture.definition()) { journal, url in
            _ = try await HeartRatePlannerFixture.retain([HeartRatePlannerFixture.plan()], in: journal)
            let queries = Queries()
            let acquisition = try HealthKitAcquisition(journal: journal, scope: DeliveryFixture.scope, validateSession: {})
            let first = try await acquisition.catchUp(
                localID: DeliveryFixture.epoch,
                application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
                host: .init(operatingSystemVersion: "27.2")
            ) {
                try Task.checkCancellation()
                return await queries.page($0, anchor: $1)
            }
            #expect(first == .needsAnotherPass)
            #expect(await queries.kinds == [.live] + Array(repeating: .historical, count: 7))
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let restored = try HealthKitAcquisition(journal: reopened, scope: DeliveryFixture.scope, validateSession: {})
            let second = try await restored.catchUp(
                localID: DeliveryFixture.epoch,
                application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
                host: .init(operatingSystemVersion: "27.2")
            ) {
                await queries.page($0, anchor: $1)
            }
            #expect(second == .needsAnotherPass)
            #expect(await queries.kinds == Array(repeating: [.live] + Array(repeating: .historical, count: 7), count: 2).flatMap { $0 })
            #expect(try await reopened.pendingDeliveryIDs().isEmpty)
            await reopened.close()
        }
    }

    @Test
    func sampleSpanningTheSplitIsKeptExactlyInTheHistoricalPartition() throws {
        let split = HeartRatePlannerFixture.liveStart
        let sample = HKQuantitySample(
            type: HKQuantityType(.heartRate),
            quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: 72),
            start: split.addingTimeInterval(-1),
            end: split.addingTimeInterval(1)
        )
        let atSplit = HKQuantitySample(type: sample.quantityType, quantity: sample.quantity, start: split, end: split)
        let delta = HealthKitAcquisition.Delta(added: [sample, atSplit], deletedIDs: [], nextAnchor: QueryAnchor(HKQueryAnchor(fromValue: 1)))
        let history = try HealthKitQueryDefinition(profile: .heartRate, kind: .historical, start: split.addingTimeInterval(-10), end: split)
        let live = try HealthKitQueryDefinition(profile: .heartRate, kind: .live, start: split)
        #expect(try HealthKitAcquisition.partition(delta, definition: history).added.map(\.uuid) == [sample.uuid])
        #expect(try HealthKitAcquisition.partition(delta, definition: live).added.map(\.uuid) == [atSplit.uuid])
        let predicate = HKQuery.predicateForSamples(withStart: history.start, end: history.end, options: [.strictStartDate])
        #expect(predicate.evaluate(with: sample))
        #expect(!predicate.evaluate(with: atSplit))
    }
}

#endif
