// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import GroveFHIRContract
import ModelsR4
import Testing
import TroveAPITypes
@testable import TroveServer


struct FHIRHealthKitAudiogramTests {
    private static func quantity(_ number: Double, code: String) -> [String: Any] {
        ["value": number, "system": "http://unitsofmeasure.org", "code": code, "unit": code]
    }

    private static func component(frequency: Double, masked: Bool) throws -> [String: Any] {
        let measurement = try #require(CollectionObservationProfile.audiogram.measurement)
        let contract = measurement.components.first { $0.id == "left-250" }
        let code: [String: Any]
        if frequency == 250, let contract {
            code = ["coding": [["system": contract.code.system, "code": contract.code.value]]]
        } else {
            code = ["text": "Air conduction threshold, left ear, exact source frequency"]
        }
        let fields: [[String: Any]] = [
            ["url": "frequency", "valueQuantity": quantity(frequency, code: "Hz")],
            ["url": "ear", "valueCode": "left"], ["url": "conduction", "valueCode": "air"],
            ["url": "masked", "valueBoolean": masked],
            ["url": "clampingRange", "valueRange": ["low": quantity(-10, code: "dB"), "high": quantity(80, code: "dB")]]
        ]
        return [
            "code": code,
            "valueQuantity": quantity(25.125, code: "dB"),
            "extension": [["url": FHIRHealthKitAudiogramBoundary.url, "extension": fields]]
        ]
    }

    /// A synthetic receiver fixture uses a known exchange graph; official IG validation is a separate boundary.
    private static func bundle(components: [[String: Any]]) throws -> Data {
        let location = try #require(Bundle.module.url(
            forResource: "high-heart-rate-threshold", withExtension: "json", subdirectory: "HealthKitComponentEvents"
        ))
        var bundle = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: location)) as? [String: Any])
        var entries = try #require(bundle["entry"] as? [[String: Any]])
        let index = try #require(entries.firstIndex { ($0["resource"] as? [String: Any])?["resourceType"] as? String == "Observation" })
        var observation = try #require(entries[index]["resource"] as? [String: Any])
        let measurement = try #require(CollectionObservationProfile.audiogram.measurement)
        observation["meta"] = ["profile": [CollectionObservationProfile.audiogram.rawValue]]
        observation["code"] = ["coding": [["system": measurement.code.system, "code": measurement.code.value]]]
        observation["component"] = components
        observation.removeValue(forKey: "valueCodeableConcept")
        observation["effectivePeriod"] = ["start": "2026-08-17T22:25:00Z", "end": "2026-08-17T22:30:00Z"]
        let sourceExtension: [String: Any] = [
            "url": Canonicals.healthKitSourceTypeExtension.value?.url.absoluteString ?? "",
            "valueCode": try #require(CollectionObservationProfile.audiogram.nativeSourceTypeIdentifier)
        ]
        observation["extension"] = [sourceExtension]
        entries[index]["resource"] = observation
        bundle["entry"] = entries
        return try JSONSerialization.data(withJSONObject: bundle, options: [.sortedKeys])
    }

    @Test
    func exactTestsRetainMaskingClampingArbitraryFrequencyAndOriginalBytes() throws {
        let bytes = try Self.bundle(components: [Self.component(frequency: 250, masked: true), Self.component(frequency: 1_250, masked: false)])
        let projection = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "synthetic-audiogram-receiver")
        #expect(projection.rawBytes == bytes && projection.outputs.count == 1)
        #expect(projection.outputs.first?.value == .components)
        let json = String(decoding: projection.rawBytes, as: UTF8.self)
        #expect(json.contains("25.125") && json.contains("clampingRange") && json.contains("1250"))
    }

    @Test(arguments: [
        "duplicate", "missing-details", "wrong-ear-code", "wrong-unit", "wrong-frequency-unit", "zero-frequency", "reversed-clamp",
        "reference", "modifier", "wrong-profile"
    ])
    func malformedOrUnrelatedComponentsDoNotBecomeAudiogramMeasurements(corruption: String) throws {
        var component = try Self.component(frequency: 250, masked: true)
        var extensions = try #require(component["extension"] as? [[String: Any]])
        var fields = try #require(extensions[0]["extension"] as? [[String: Any]])
        switch corruption {
        case "wrong-ear-code": fields[1]["valueCode"] = "right"
        case "wrong-unit": component["valueQuantity"] = Self.quantity(25, code: "kg")
        case "wrong-frequency-unit": fields[0]["valueQuantity"] = Self.quantity(250, code: "dB")
        case "zero-frequency": fields[0]["valueQuantity"] = Self.quantity(0, code: "Hz")
        case "reversed-clamp": fields[4]["valueRange"] = ["low": Self.quantity(80, code: "dB"), "high": Self.quantity(-10, code: "dB")]
        case "reference": fields[0] = ["url": "frequency", "valueReference": ["reference": "Patient/other"]]
        case "modifier": fields[0]["modifierExtension"] = [["url": "https://example.test/modifier", "valueBoolean": true]]
        default: break
        }
        extensions[0]["extension"] = fields
        component["extension"] = corruption == "missing-details" ? nil : extensions
        let bytes = try Self.bundle(components: corruption == "duplicate" ? [component, component] : [component])
        if corruption == "wrong-profile" {
            let data = try JSONSerialization.data(withJSONObject: component)
            let component = try JSONDecoder().decode(ObservationComponent.self, from: data)
            var observation = Observation(code: CodeableConcept(), status: .init(.final))
            observation.component = [component]
            let measurement = try #require(CollectionObservationProfile.heartRate.measurement)
            #expect(throws: (any Error).self) { try FHIRComponentProjection.validateSupplemental(observation, measurement: measurement) }
        } else {
            #expect(throws: (any Error).self) {
                try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "synthetic-audiogram-receiver")
            }
        }
    }
}
