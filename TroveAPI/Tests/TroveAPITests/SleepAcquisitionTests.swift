//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

#if canImport(HealthKit)

import Foundation
import GroveFHIRContract
import GroveHealthKit
import HealthKit
import ModelsR4
import Testing
@testable import TroveAPIClient
@testable import TroveHealthKit


struct SleepAcquisitionTests {
    private typealias Fixture = HeartRatePlannerFixture

    @Test
    func spanningSleepIsSelectedWholeByBothQueriesAndEncodedOnceForTwoStudies() async throws {
        let definition = try HealthKitQueryDefinition(profile: .sleepStage, kind: .live, start: Fixture.liveStart)
        try await DeliveryFixture.withJournal(query: definition.encoded()) { journal, _ in
            let state = try await Self.retainPlans(in: journal)
            let snapshot = try #require(state.snapshot)
            let plan = try await journal.healthKitQueryPlan(for: DeliveryFixture.sourceID, state: state, at: Fixture.liveStart)
            let sample = Self.sample()
            let delta = HealthKitAcquisition.Delta(added: [sample], deletedIDs: [], nextAnchor: QueryAnchor(HKQueryAnchor(fromValue: 1)))
            let app = try ApplicationDevice(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1", build: "1")
            let host = try HostDevice(operatingSystemVersion: "27.2")
            let configuration = try HealthKitAcquisition.conversionConfiguration(application: app, host: host)
            let setup = try await journal.sourceSetup(for: DeliveryFixture.epoch)
            let exporter = try await HealthKitAcquisition.exporter(
                source: #require(setup.binding).source, privacy: journal.identityScope(for: DeliveryFixture.sourceID), application: app, host: host
            )
            var bytes: Data?, deliveryIDs: [UUID] = []
            for (index, query) in plan.queries.enumerated() {
                let selected = try HealthKitAcquisition.partition(delta, definition: query.definition)
                #expect(selected.added.map(\.uuid) == [sample.uuid])
                let time = Fixture.date(200 + Double(index))
                let recordedAt = try await journal.healthKitConversionInstants(
                    for: [sample.uuid], configuration: configuration, from: query.checkpoint, at: time
                )
                let prepared = try await HealthKitAcquisition.prepare(
                    selected,
                    exporter: exporter,
                    snapshot: snapshot,
                    timing: .init(batchInstant: time, records: recordedAt, deletions: [:]),
                    profile: .sleepStage
                )
                let payload = try #require(prepared.payloads.first)
                #expect(prepared.payloads.count == 1 && payload.targets.count == 2)
                if let bytes { #expect(payload.bytes == bytes) }
                bytes = payload.bytes
                deliveryIDs += try await journal.stage(from: query.checkpoint, nextCursor: Data([1]), payloads: prepared.payloads)
            }
            #expect(plan.queries.count == 2 && Set(deliveryIDs).count == 1)
            try Self.verify(#require(bytes), sample: sample)
        }
    }
}

extension SleepAcquisitionTests {
    private static func retainPlans(in journal: EventDeliveryJournal) async throws -> ParticipantCollectionState {
        var first = Fixture.plan(start: 50, end: 125), second = Fixture.plan(start: 75, end: 175)
        first.windows[0].requirements[0].profile = ParticipantCollectionSnapshot.sleepStageProfile
        second.windows[0].requirements[0].profile = ParticipantCollectionSnapshot.sleepStageProfile
        return try await Fixture.retain([first, second], in: journal)
    }

    private static func sample() -> HKCategorySample {
        HKCategorySample(
            type: HKCategoryType(.sleepAnalysis),
            value: HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            start: Fixture.date(25),
            end: Fixture.date(150)
        )
    }

    private static func verify(_ bytes: Data, sample: HKSample) throws {
        let graph = try ExchangeGraph(validating: bytes, kind: .active)
        let observation = try #require(graph.bundle.entry?.compactMap { entry -> Observation? in
            if case .observation(let value)? = entry.resource {
                return value
            }
            return nil
        }.first)
        guard case .period(let interval)? = observation.effective else {
            Issue.record("Sleep must retain its complete native interval")
            return
        }
        #expect(try interval.start?.value?.asNSDate() == sample.startDate)
        #expect(try interval.end?.value?.asNSDate() == sample.endDate)
    }
}

#endif
