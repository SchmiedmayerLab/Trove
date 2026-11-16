// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

#if canImport(HealthKit)

import Foundation
import GroveFHIRContract
import GroveHealthKit
import HealthKit
import Testing
@testable import TroveAPIClient
@testable import TroveHealthKit


@Suite(.serialized)
struct QuantityAcquisitionTests {
    private typealias Fixture = HeartRatePlannerFixture

    @Test(arguments: CollectionObservationProfile.quantitySources.map(\.sourceTypeIdentifier))
    func eachSelectedScalarUsesTheActualGroveConverter(sourceType: String) async throws {
        let selected = CollectionObservationProfile.allCases.first { $0.nativeSources.contains { $0.sourceTypeIdentifier == sourceType } }
        let profile = try #require(selected)
        let stream = try HealthKitQueryDefinition.Stream(profile, sourceTypeIdentifier: sourceType)
        let native = try HealthKitAcquisition.quantityType(for: stream)
        let definition = try HealthKitQueryDefinition(stream: stream, kind: .live, start: Fixture.liveStart)
        var metadata: [String: Any] = [HKMetadataKeyTimeZone: "UTC", "synthetic-source-note": "preserved"]
        if native == .insulinDelivery { metadata[HKMetadataKeyInsulinDeliveryReason] = HKInsulinDeliveryReason.bolus.rawValue }
        if native == .heartRate {
            #expect(FHIRMeasurementCatalog.healthKitHeartRateMotionContextCode == HKMetadataKeyHeartRateMotionContext)
            metadata[HKMetadataKeyHeartRateMotionContext] = HKHeartRateMotionContext.sedentary.rawValue
        }
        let sample = HKQuantitySample(
            type: native.hkSampleType,
            quantity: HKQuantity(unit: native.canonicalUnit, doubleValue: 1),
            start: Fixture.date(110),
            end: Fixture.date(120),
            metadata: metadata
        )
        try await DeliveryFixture.withJournal(query: definition.encoded()) { journal, _ in
            var plan = Fixture.plan(start: 100, end: 150)
            plan.windows[0].requirements[0].profile = profile.rawValue
            plan.windows[0].requirements[0].sourceTypeIdentifier = sourceType
            let snapshot = try #require(await Fixture.retain([plan], in: journal).snapshot)
            let source = try #require(await journal.sourceSetup(for: DeliveryFixture.epoch).binding).source
            let exporter = try await HealthKitAcquisition.exporter(
                source: source,
                privacy: journal.identityScope(for: DeliveryFixture.sourceID),
                application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1", build: "1"),
                host: .init(operatingSystemVersion: "27.2"),
                stream: stream
            )
            let delta = HealthKitAcquisition.Delta(
                added: [sample], deletedIDs: [], nextAnchor: QueryAnchor(HKQueryAnchor(fromValue: 1))
            )
            #expect(try HealthKitAcquisition.partition(delta, definition: definition).added.count == 1)
            let prepared = try await HealthKitAcquisition.prepare(
                delta,
                exporter: exporter,
                snapshot: snapshot,
                timing: .init(batchInstant: Fixture.date(200), records: [sample.uuid: Fixture.date(200)], deletions: [:]),
                stream: stream
            )
            #expect(prepared.payloads.count == 1)
            let payload = try #require(prepared.payloads.first)
            #expect(payload.targets.map(\.consentID) == [try #require(UUID(uuidString: plan.windows[0].consentId))])
            try verify(payload.bytes, sample: sample, profile: profile)
        }
    }

    private func verify(_ bytes: Data, sample: HKQuantitySample, profile: CollectionObservationProfile) throws {
        let graph = try ExchangeGraph(validating: bytes, kind: .active)
        let observations = (graph.bundle.entry ?? []).compactMap { entry in
            if case .observation(let observation)? = entry.resource { observation } else { nil }
        }
        let observation = try #require(observations.first)
        let definition = try #require(profile.measurement)
        #expect(observations.count == 1 && observation.meta?.profile?.contains(definition.profile) == true)
        guard case .quantity(let quantity)? = observation.value else {
            Issue.record("Selected quantity produced no scalar value")
            return
        }
        #expect(quantity.code?.value?.string == profile.measurement?.quantity?.code)
        #expect(quantity.system?.value?.url.absoluteString == profile.measurement?.quantity?.system)
        #expect(quantity.value?.value != nil)
        switch observation.effective {
        case .period(let period):
            #expect(profile.permitsEffectiveTime(hasEnd: true))
            #expect(try period.start?.value?.asNSDate() == sample.startDate)
            #expect(try period.end?.value?.asNSDate() == sample.endDate)
        case .dateTime(let instant):
            #expect(profile.permitsEffectiveTime(hasEnd: false))
            #expect(try instant.value?.asNSDate() == sample.startDate)
        default: Issue.record("Selected quantity produced no supported effective time")
        }
        let text = String(decoding: bytes, as: UTF8.self)
        for fact in [sample.uuid.uuidString.lowercased(), "synthetic-source-note", "preserved", "Provenance"] {
            #expect(text.contains(fact))
        }
    }
}
#endif
