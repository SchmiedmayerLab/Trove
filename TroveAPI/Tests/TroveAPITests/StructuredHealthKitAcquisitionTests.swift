// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

#if canImport(HealthKit)

import Foundation
import GroveFHIRContract
import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit
import ModelsR4
import Testing
@testable import TroveAPIClient
@testable import TroveHealthKit


@Suite(.serialized)
struct StructuredHealthKitAcquisitionTests {
    private typealias Fixture = HeartRatePlannerFixture

    private static let profiles: [CollectionObservationProfile] = [.bloodPressure, .stateOfMind, .gad7, .phq9, .audiogram]

    @available(iOS 18.1, macOS 15.1, watchOS 11.1, visionOS 2.1, *)
    private static func sample(_ profile: CollectionObservationProfile) throws -> HKSample {
        let date = Fixture.date(110)
        let metadata: [String: Any] = [HKMetadataKeyTimeZone: "UTC", "synthetic-source-note": "preserved"]
        switch profile {
        case .stateOfMind:
            return HKStateOfMind(date: date, kind: .momentaryEmotion, valence: 0.5, labels: [.happy], associations: [.work], metadata: metadata)
        case .gad7:
            return HKGAD7Assessment(date: date, answers: Array(repeating: .severalDays, count: 7), metadata: metadata)
        case .phq9:
            return HKPHQ9Assessment(date: date, answers: Array(repeating: .severalDays, count: 9), metadata: metadata)
        case .audiogram: return try audiogram(metadata: metadata)
        case .bloodPressure:
            let systolic = HKQuantitySample(
                type: HKQuantityType(.bloodPressureSystolic),
                quantity: HKQuantity(unit: .millimeterOfMercury(), doubleValue: 120),
                start: date,
                end: date
            )
            let diastolic = HKQuantitySample(
                type: HKQuantityType(.bloodPressureDiastolic),
                quantity: HKQuantity(unit: .millimeterOfMercury(), doubleValue: 80),
                start: date,
                end: date
            )
            return HKCorrelation(type: HKCorrelationType(.bloodPressure), start: date, end: date, objects: [systolic, diastolic], metadata: metadata)
        default: throw HealthKitAcquisition.AcquisitionError.unsupportedDelta
        }
    }

    @available(iOS 18.1, macOS 15.1, watchOS 11.1, visionOS 2.1, *)
    private static func audiogram(metadata: [String: Any]) throws -> HKAudiogramSample {
        let bounds = try HKAudiogramSensitivityPointClampingRange(lowerBound: -10, upperBound: 80)
        let test = try HKAudiogramSensitivityTest(
            sensitivity: HKQuantity(unit: .decibelHearingLevel(), doubleValue: 25),
            type: .air,
            masked: true,
            side: .left,
            clampingRange: bounds
        )
        let points = try [250.0, 1_250.0].map { hertz in
            try HKAudiogramSensitivityPoint(frequency: HKQuantity(unit: .hertz(), doubleValue: hertz), tests: [test])
        }
        return HKAudiogramSample(sensitivityPoints: points, start: Fixture.date(90), end: Fixture.date(160), device: nil, metadata: metadata)
    }

    @available(iOS 18.1, macOS 15.1, watchOS 11.1, visionOS 2.1, *)
    @Test(arguments: profiles)
    func structuredSamplesRetainTheirNativeValuesAndIndependentConsent(profile: CollectionObservationProfile) async throws {
        let sourceType = try #require(profile.nativeSourceTypeIdentifier)
        let stream = try HealthKitQueryDefinition.Stream(profile)
        let definition = try HealthKitQueryDefinition(stream: stream, kind: .live, start: Fixture.liveStart)
        let sample = try Self.sample(profile)
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
            if profile == .audiogram, let directory = ProcessInfo.processInfo.environment["TROVE_NATIVE_HEALTHKIT_FIXTURE_DIRECTORY"] {
                let destination = URL(filePath: directory, directoryHint: .isDirectory).appending(path: "audiogram.json")
                try payload.bytes.write(to: destination, options: .withoutOverwriting)
            }
        }
    }

    private func verify(_ bytes: Data, sample: HKSample, profile: CollectionObservationProfile) throws {
        let graph = try ExchangeGraph(validating: bytes, kind: .active)
        let observations = (graph.bundle.entry ?? []).compactMap { entry in
            if case .observation(let observation)? = entry.resource { observation } else { nil }
        }
        let observation = try #require(observations.first)
        let definition = try #require(profile.measurement)
        #expect(observations.count == 1 && observation.meta?.profile?.contains(definition.profile) == true)
        try verifyValue(observation, profile: profile, definition: definition)
        switch observation.effective {
        case .period(let period):
            #expect(profile.permitsEffectiveTime(hasEnd: true))
            #expect(try period.start?.value?.asNSDate() == sample.startDate)
            #expect(try period.end?.value?.asNSDate() == sample.endDate)
        case .dateTime(let instant):
            #expect(profile.permitsEffectiveTime(hasEnd: false))
            #expect(try instant.value?.asNSDate() == sample.startDate)
        default: Issue.record("Structured sample produced no supported effective time")
        }
        let text = String(decoding: bytes, as: UTF8.self)
        for fact in [sample.uuid.uuidString.lowercased(), "synthetic-source-note", "preserved", "Provenance"] {
            #expect(text.contains(fact))
        }
    }
    private func verifyValue(
        _ observation: Observation, profile: CollectionObservationProfile, definition: FHIRMeasurementDefinition
    ) throws {
        switch observation.value {
        case .quantity(let quantity):
            #expect(definition.valueShape == .quantity && quantity.value?.value != nil)
            #expect(quantity.code?.value?.string == definition.quantity?.code)
            let expected = profile == .gad7 ? Decimal(7) : profile == .phq9 ? Decimal(9) : Decimal(string: "0.5")
            #expect(quantity.value?.value?.decimal == expected)
            if profile == .stateOfMind { #expect(observation.component?.count == 4) }
        case .codeableConcept(let concept):
            #expect(definition.valueShape == .coded)
            #expect(concept.coding?.contains { $0.system?.value?.url.absoluteString == definition.resultCodeSystem } == true)
        case nil:
            if profile == .audiogram {
                try verifyAudiogram(observation)
                return
            }
            #expect(profile == .bloodPressure)
            let components = try #require(observation.component)
            #expect(components.count == 2)
            let values = components.compactMap { component -> Decimal? in
                guard case .quantity(let quantity)? = component.value else {
                    return nil
                }
                #expect(quantity.code?.value?.string == "mm[Hg]")
                return quantity.value?.value?.decimal
            }
            #expect(Set(values) == [120, 80])
        default: Issue.record("Structured sample produced an unsupported value")
        }
    }

    private func verifyAudiogram(_ observation: Observation) throws {
        let components = try #require(observation.component)
        #expect(components.count == 2)
        for (component, frequency) in zip(components, [250, 1_250]) {
            guard case .quantity(let sensitivity)? = component.value else {
                Issue.record("Audiogram sensitivity must retain a quantity")
                return
            }
            #expect(sensitivity.value?.value?.decimal == 25 && sensitivity.code?.value?.string == "dB")
            let details = try #require(component.extension?.first)
            #expect(details.url == Canonicals.healthKitAudiogramTestDetails)
            let fields = try #require(details.extension)
            #expect(fields.first { $0.url.value?.url.absoluteString == "masked" }?.value == .boolean(true))
            guard case .quantity(let hertz)? = fields.first(where: { $0.url.value?.url.absoluteString == "frequency" })?.value,
                  case .range(let range)? = fields.first(where: { $0.url.value?.url.absoluteString == "clampingRange" })?.value else {
                Issue.record("Audiogram source frequency and clamping range must be retained")
                return
            }
            #expect(hertz.value?.value?.decimal == Decimal(frequency) && hertz.code?.value?.string == "Hz")
            #expect(range.low?.value?.value?.decimal == -10 && range.high?.value?.value?.decimal == 80)
            #expect(frequency == 250 ? component.code.coding?.count == 1 : component.code.coding == nil)
        }
    }
}
#endif
