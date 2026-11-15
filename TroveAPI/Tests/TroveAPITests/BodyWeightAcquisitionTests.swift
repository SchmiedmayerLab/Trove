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


struct BodyWeightAcquisitionTests {
    private typealias Fixture = HeartRatePlannerFixture

    @Test(arguments: [false, true])
    func groveBodyMassConversionRetainsSourceFactsAndOnlyBodyWeightStudyTargets(pounds: Bool) async throws {
        let definition = try HealthKitQueryDefinition(profile: .bodyWeight, kind: .live, start: Fixture.liveStart)
        try await DeliveryFixture.withJournal(query: definition.encoded()) { journal, _ in
            var first = Fixture.plan(start: 50, end: 125), second = Fixture.plan(start: 75, end: 175)
            first.windows[0].requirements[0].profile = CollectionObservationProfile.bodyWeight.rawValue
            second.windows[0].requirements[0].profile = CollectionObservationProfile.bodyWeight.rawValue
            let state = try await Fixture.retain([first, second, Fixture.plan()], in: journal)
            let sample = Self.sample(pounds: pounds)
            let delta = HealthKitAcquisition.Delta(added: [sample], deletedIDs: [], nextAnchor: QueryAnchor(HKQueryAnchor(fromValue: 1)))
            #expect(try HealthKitAcquisition.sampleType(for: CollectionObservationProfile.bodyWeight) == HKQuantityType(.bodyMass))
            #expect(try HealthKitAcquisition.partition(delta, definition: definition).added.map(\.uuid) == [sample.uuid])
            let prepared = try await Self.prepare(delta, journal: journal, snapshot: #require(state.snapshot))
            let payload = try #require(prepared.payloads.first)
            #expect(prepared.payloads.count == 1 && payload.targets.count == 2)
            let permitted = Set([first, second].compactMap { UUID(uuidString: $0.windows[0].consentId) })
            #expect(Set(payload.targets.map(\.consentID)) == permitted)
            try Self.verify(payload.bytes, sample: sample, expected: pounds ? 72.5747792 : 72.5)
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let ids = try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: prepared.payloads)
            let firstID = try #require(ids.first)
            let attempt = try #require(await journal.prepareAttempt(firstID))
            #expect(attempt.bytes == payload.bytes)
        }
    }
}


extension BodyWeightAcquisitionTests {
    private static func prepare(
        _ delta: HealthKitAcquisition.Delta, journal: EventDeliveryJournal, snapshot: ParticipantCollectionSnapshot
    ) async throws -> HealthKitAcquisition.PreparedPage {
        let app = try ApplicationDevice(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1", build: "1")
        let host = try HostDevice(operatingSystemVersion: "27.2")
        let setup = try await journal.sourceSetup(for: DeliveryFixture.epoch)
        let exporter = try await HealthKitAcquisition.exporter(
            source: #require(setup.binding).source,
            privacy: journal.identityScope(for: DeliveryFixture.sourceID),
            application: app,
            host: host,
            stream: .bodyWeight
        )
        return try await HealthKitAcquisition.prepare(
            delta,
            exporter: exporter,
            snapshot: snapshot,
            timing: .init(
                batchInstant: Fixture.date(200),
                records: Dictionary(uniqueKeysWithValues: delta.added.map { ($0.uuid, Fixture.date(200)) }),
                deletions: [:]
            ),
            profile: .bodyWeight
        )
    }

    private static func sample(pounds: Bool) -> HKQuantitySample {
        let device = HKDevice(
            name: "Synthetic Scale",
            manufacturer: "Synthetic Manufacturer",
            model: "Scale Model",
            hardwareVersion: nil,
            firmwareVersion: nil,
            softwareVersion: nil,
            localIdentifier: nil,
            udiDeviceIdentifier: nil
        )
        return HKQuantitySample(
            type: HKQuantityType(.bodyMass),
            quantity: HKQuantity(unit: pounds ? .pound() : .gramUnit(with: .kilo), doubleValue: pounds ? 160 : 72.5),
            start: Fixture.date(110),
            end: Fixture.date(120),
            device: device,
            metadata: [HKMetadataKeyTimeZone: "UTC", HKMetadataKeyWasUserEntered: true, "synthetic-scale-note": "retained"]
        )
    }

    private static func verify(_ bytes: Data, sample: HKSample, expected: Double) throws {
        let bundle = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let entries = try #require(bundle["entry"] as? [[String: Any]])
        let resources = entries.compactMap { $0["resource"] as? [String: Any] }
        let observation = try #require(resources.first { $0["resourceType"] as? String == "Observation" })
        let quantity = try #require(observation["valueQuantity"] as? [String: Any])
        #expect(abs(try #require(quantity["value"] as? Double) - expected) < 0.0000001)
        #expect(quantity["code"] as? String == "kg")
        #expect(observation["effectivePeriod"] == nil)
        #expect(try TroveDateTranscoder().decode(#require(observation["effectiveDateTime"] as? String)) == sample.startDate)
        let primitive = try #require(observation["_effectiveDateTime"] as? [String: Any])
        let extensions = try #require(primitive["extension"] as? [[String: Any]])
        let expectedZone = try #require(TimeZone(identifier: "UTC")).identifier
        #expect(extensions.contains {
            $0["url"] as? String == "http://hl7.org/fhir/StructureDefinition/timezone" && $0["valueCode"] as? String == expectedZone
        })
        let identifiers = try #require(observation["identifier"] as? [[String: Any]])
        #expect(identifiers.contains { $0["value"] as? String == sample.uuid.uuidString.lowercased() })
        let text = String(decoding: bytes, as: UTF8.self)
        for fact in [CollectionObservationProfile.bodyWeight.rawValue, "29463-7", "manual-entry", "Synthetic Manufacturer", "synthetic-scale-note"] {
            #expect(text.contains(fact))
        }
        #expect(resources.contains { $0["resourceType"] as? String == "Provenance" })
    }
}
#endif
