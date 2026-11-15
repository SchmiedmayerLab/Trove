// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import TroveAPITypes
@testable import TroveServer


struct FHIRHealthKitECGTests {
    private typealias Mutation = @Sendable (_ waveform: inout [String: Any], _ average: inout [String: Any], _ averageURL: String) -> Void

    private static let waveformMutations: [String: Mutation] = [
        "lead": { waveform, _, _ in
            var components = waveform["component"] as? [[String: Any]] ?? []
            components[0]["code"] = ["coding": [["system": FHIRHealthKitECGBoundary.leadSystem, "code": "131330"]]]
            waveform["component"] = components
        },
        "second-component": { waveform, _, _ in
            let components = waveform["component"] as? [[String: Any]] ?? []
            waveform["component"] = components + components
        },
        "classification": { waveform, _, _ in
            waveform["interpretation"] = [["coding": [["system": "https://example.test/rhythm", "code": "sinusRhythm"]]]]
        },
        "missing-interpretation": { waveform, _, _ in waveform.removeValue(forKey: "interpretation") },
        "algorithm-version": { waveform, _, _ in
            waveform["method"] = ["coding": [["system": "https://example.test/version", "code": "version2"]]]
        },
        "literal-member": { waveform, _, averageURL in waveform["hasMember"] = [["reference": averageURL]] },
        "unknown-extension": { waveform, _, _ in
            let extensions = waveform["extension"] as? [[String: Any]] ?? []
            waveform["extension"] = extensions + [["url": "https://example.test/ecg-note", "valueString": "note"]]
        },
        "single-waveform-profile": { waveform, _, _ in
            waveform["meta"] = ["profile": [CollectionObservationProfile.electrocardiogram.rawValue]]
        },
        "average-period": { _, average, _ in
            average["effectivePeriod"] = ["start": "2026-08-17T15:30:00-07:00", "end": "2026-08-17T15:30:30-07:00"]
        },
        "average-origin": { _, average, _ in average.removeValue(forKey: "derivedFrom") },
        "control": { _, _, _ in }
    ]

    static func bytes(_ name: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "HealthKitComponentEvents")))
    }

    private static func project(_ bytes: Data) throws -> ValidatedExchangeEvent {
        try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "synthetic-ecg-receiver")
    }

    private static func profiles(_ entry: [String: Any]) -> [String] {
        ((entry["resource"] as? [String: Any])?["meta"] as? [String: Any])?["profile"] as? [String] ?? []
    }

    private static func mutated(_ corruption: String) throws -> Data {
        var bundle = try #require(JSONSerialization.jsonObject(with: bytes("electrocardiogram-with-symptom")) as? [String: Any])
        var entries = try #require(bundle["entry"] as? [[String: Any]])
        let waveformIndex = try #require(entries.firstIndex { profiles($0).contains(CollectionObservationProfile.electrocardiogram.rawValue) })
        let averageIndex = try #require(entries.firstIndex { profiles($0).contains(FHIRHealthKitECGBoundary.averageHeartRateProfile) })
        var waveform = try #require(entries[waveformIndex]["resource"] as? [String: Any])
        var average = try #require(entries[averageIndex]["resource"] as? [String: Any])
        let mutation = try #require(waveformMutations[corruption])
        mutation(&waveform, &average, try #require(entries[averageIndex]["fullUrl"] as? String))
        entries[waveformIndex]["resource"] = waveform
        entries[averageIndex]["resource"] = average
        bundle["entry"] = entries
        return try JSONSerialization.data(withJSONObject: bundle, options: [.sortedKeys])
    }

    /// Exact Grove producer records exercise receiver support; this is not a substitute for official IG validation.
    @Test(arguments: ["electrocardiogram", "electrocardiogram-with-symptom"])
    func waveformAndDerivedAverageHeartRateRemainOneRecord(fixture: String) throws {
        let bytes = try Self.bytes(fixture)
        let event = try Self.project(bytes)
        #expect(event.rawBytes == bytes && event.outputs.count == 2)
        let waveform = try #require(event.outputs.first { $0.profile == CollectionObservationProfile.electrocardiogram.rawValue })
        let average = try #require(event.outputs.first { $0.profile == CollectionObservationProfile.heartRate.rawValue })
        #expect(waveform.value == .components && waveform.code == "11524-6" && waveform.measurementBounds.end != nil)
        #expect(average.value == .quantity(value: "72", system: "http://unitsofmeasure.org", code: "/min"))
        #expect(waveform.sourceRecordIdentifier == average.sourceRecordIdentifier)
        #expect(Set(event.outputs.map(\.sourceTypeIdentifier)) == ["HKDataTypeIdentifierElectrocardiogram"])
        #expect(event.outputDependencies.map(\.targetFullURL) == [waveform.fullURL])
        let collected = try FHIRHealthKitECGBoundary.collectionOutputs(event.collectionOutputs)
        #expect(collected.allSatisfy { $0.profile == waveform.profile && $0.measurementBounds == waveform.measurementBounds })
        #expect(throws: ServerError.self) {
            try FHIRHealthKitECGBoundary.requireCompleteSelection([waveform.fullURL], outputs: event.collectionOutputs)
        }
    }

    @Test
    func correlatedSymptomIsAnIndependentRecord() throws {
        let symptom = try Self.project(Self.bytes("electrocardiogram-symptom-companion"))
        let output = try #require(symptom.outputs.first)
        #expect(symptom.outputs.count == 1 && output.value != .components)
        #expect(output.sourceTypeIdentifier == "HKCategoryTypeIdentifierChestTightnessOrPain")
        let waveform = try Self.project(Self.bytes("electrocardiogram-with-symptom"))
        #expect(!waveform.outputs.contains { $0.sourceRecordIdentifier == output.sourceRecordIdentifier })
    }

    @Test(arguments: waveformMutations.keys.sorted())
    func malformedWaveformsAndDetachedAveragesAreRefused(corruption: String) throws {
        let bytes = try Self.mutated(corruption)
        if corruption == "control" {
            #expect(try Self.project(bytes).outputs.count == 2)
        } else {
            #expect(throws: (any Error).self) { try Self.project(bytes) }
        }
    }

    @Test
    func capabilityIsAnIntervalWithBothConsentTitles() throws {
        let capabilities = try NativeCollectionCapabilities.values().filter { $0.profile == CollectionObservationProfile.electrocardiogram.rawValue }
        let capability = try #require(capabilities.first)
        #expect(capabilities.count == 1 && capability.sourceTypeIdentifier == "HKDataTypeIdentifierElectrocardiogram")
        #expect(capability.effectiveTime == .interval && capability.repositoryKind == .healthkit && capability.isOriginalRecording == false)
        #expect(!capability.displayNameEnglish.isEmpty && !capability.displayNameGerman.isEmpty)
        #expect(capability.displayNameEnglish != capability.displayNameGerman)
    }
}
