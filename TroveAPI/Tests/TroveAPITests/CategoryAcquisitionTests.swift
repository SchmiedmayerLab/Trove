// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

#if canImport(HealthKit)

import Foundation
import GroveFHIRContract
import GroveHealthKit
@testable import GroveHealthKitFHIR
import HealthKit
import Testing
@testable import TroveAPIClient
@testable import TroveHealthKit


@Suite(.serialized)
struct CategoryAcquisitionTests {
    private typealias Fixture = HeartRatePlannerFixture

    /// Reuse Grove's admitted native vocabulary only to construct fixtures. This suite tests Trove's
    /// acquisition/scope/output path; Grove's conformance suites independently verify category mappings.
    private static func fixtureValue(_ identifier: String) throws -> Int {
        let type = try #require(HealthKitSourceType(rawValue: identifier))
        let group = try #require(HealthKitContentRules.groups.first { $0.types.contains(type) })
        if case .observation(.coded(let table)) = group.rule {
            return try #require(table.rows.first).raw
        }
        return HKCategoryValue.notApplicable.rawValue
    }

    @Test(arguments: CollectionObservationProfile.categorySources.map(\.sourceTypeIdentifier))
    func eachSelectedCategoryTraversesAcquisitionConsentAndTheExistingConverter(sourceType: String) async throws {
        let selected = CollectionObservationProfile.allCases.first { $0.nativeSources.contains { $0.sourceTypeIdentifier == sourceType } }
        let profile = try #require(selected)
        let stream = try HealthKitQueryDefinition.Stream(profile, sourceTypeIdentifier: sourceType)
        let native = try HealthKitAcquisition.categoryType(for: stream)
        let definition = try HealthKitQueryDefinition(stream: stream, kind: .live, start: Fixture.liveStart)
        var metadata: [String: Any] = [HKMetadataKeyTimeZone: "UTC", "synthetic-source-note": "preserved"]
        if native == .menstrualFlow { metadata[HKMetadataKeyMenstrualCycleStart] = true }
        let duration = native.hkSampleType.isMaximumDurationRestricted ? min(10, native.hkSampleType.maximumAllowedDuration) : 10
        let sample = HKCategorySample(
            type: native.hkSampleType,
            value: try Self.fixtureValue(sourceType),
            start: Fixture.date(110),
            end: Fixture.date(110).addingTimeInterval(duration),
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

    private func verify(_ bytes: Data, sample: HKCategorySample, profile: CollectionObservationProfile) throws {
        let graph = try ExchangeGraph(validating: bytes, kind: .active)
        let observations = (graph.bundle.entry ?? []).compactMap { entry in
            if case .observation(let observation)? = entry.resource { observation } else { nil }
        }
        let observation = try #require(observations.first)
        let definition = try #require(profile.measurement)
        #expect(observations.count == 1 && observation.meta?.profile?.contains(definition.profile) == true)
        switch observation.value {
        case .quantity(let quantity):
            #expect(definition.valueShape == .quantity && quantity.value?.value != nil)
            #expect(quantity.code?.value?.string == definition.quantity?.code)
        case .codeableConcept(let concept):
            #expect(definition.valueShape == .coded)
            #expect(concept.coding?.contains { $0.system?.value?.url.absoluteString == definition.resultCodeSystem } == true)
        default: Issue.record("Selected category produced no supported scalar or coded value")
        }
        switch observation.effective {
        case .period(let period):
            #expect(profile.permitsEffectiveTime(hasEnd: true))
            #expect(try period.start?.value?.asNSDate() == sample.startDate)
            #expect(try period.end?.value?.asNSDate() == sample.endDate)
        case .dateTime(let instant):
            #expect(profile.permitsEffectiveTime(hasEnd: false))
            #expect(try instant.value?.asNSDate() == sample.startDate)
        default: Issue.record("Selected category produced no supported effective time")
        }
        let text = String(decoding: bytes, as: UTF8.self)
        for fact in [sample.uuid.uuidString.lowercased(), "synthetic-source-note", "preserved", "Provenance"] {
            #expect(text.contains(fact))
        }
    }
}
#endif
