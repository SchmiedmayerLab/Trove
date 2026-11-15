// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import ModelsR4
import Testing
@testable import TroveServer


struct FHIRHealthKitMetadataTests {
    @Test(arguments: ["valueString", "valueBoolean", "valueDecimal", "valueDateTime", "valueCoding", "valueQuantity"])
    func retainsTypedFactsWithoutReplacingClinicalQuantity(member: String) throws {
        let metadata = Self.metadata(member: member)
        let bytes = try observationBytes { observation in
            observation["extension"] = (observation["extension"] as? [[String: Any]] ?? []) + [metadata]
        }
        let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "synthetic-metadata-boundary")
        #expect(event.rawBytes == bytes)
        #expect(event.outputs.first?.value.quantityValue == "71.3")
        #expect(event.outputs.first?.value.quantityCode == "kg")
    }

    @Test
    func metadataCannotSupplyAMissingClinicalQuantity() throws {
        let bytes = try observationBytes { observation in
            observation.removeValue(forKey: "valueQuantity")
            observation["extension"] = (observation["extension"] as? [[String: Any]] ?? []) + [Self.metadata(member: "valueQuantity")]
        }
        #expect(throws: (any Error).self) {
            try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "synthetic-metadata-boundary")
        }
    }

    @Test(arguments: ["reference", "nested", "modifier", "primitive-extension", "duplicate-key", "wrong-resource"])
    func refusesGraphEdgesAndAmbiguousMetadata(change: String) throws {
        var metadata = Self.metadata(member: "valueString")
        var entries = try #require(metadata["extension"] as? [[String: Any]])
        var fields = try #require(entries[0]["extension"] as? [[String: Any]])
        switch change {
        case "reference": fields[1] = ["url": "value", "valueReference": ["reference": "Patient/other"]]
        case "nested": fields[1]["extension"] = [["url": "nested", "valueString": "unexpected"]]
        case "modifier": fields[1]["modifierExtension"] = [["url": "nested", "valueString": "unexpected"]]
        case "primitive-extension": fields[1]["_valueString"] = ["extension": [["url": "nested", "valueString": "unexpected"]]]
        default: break
        }
        entries[0]["extension"] = fields
        metadata["extension"] = change == "duplicate-key" ? entries + entries : entries
        let typed = try JSONDecoder().decode(Extension.self, from: JSONSerialization.data(withJSONObject: metadata))
        if ["duplicate-key", "wrong-resource", "reference", "nested"].contains(change) {
            #expect(throws: (any Error).self) {
                try FHIRHealthKitMetadataBoundary.accepts(typed, resourceType: change == "wrong-resource" ? "Patient" : "Observation")
            }
        } else {
            #expect(throws: (any Error).self) { try FHIRHealthKitMetadataBoundary.validateLocations(metadata) }
        }
    }
}


extension FHIRHealthKitMetadataTests {
    private static func metadata(member: String) -> [String: Any] {
        let values: [String: Any] = [
            "valueString": "native-source-fact", "valueBoolean": true, "valueDecimal": 123.5,
            "valueDateTime": "2026-01-02T03:04:05Z", "valueCoding": ["system": "https://example.test/codes", "code": "source"],
            "valueQuantity": ["value": 999, "system": "http://unitsofmeasure.org", "code": "kg", "unit": "kg"]
        ]
        let fields: [[String: Any]] = [
            ["url": "key", "valueString": "SourceFact"], ["url": "value", member: values[member] ?? ""]
        ]
        return ["url": FHIRHealthKitMetadataBoundary.url, "extension": [["url": "entry", "extension": fields]]]
    }

    private func observationBytes(_ change: (inout [String: Any]) -> Void) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "HealthKitBodyWeightEvent", withExtension: "json"))
        var bundle = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try #require(bundle["entry"] as? [[String: Any]])
        let index = try #require(entries.firstIndex { ($0["resource"] as? [String: Any])?["resourceType"] as? String == "Observation" })
        var observation = try #require(entries[index]["resource"] as? [String: Any])
        // Rewriting a parsed binary double would alter the decimal text that the receiver retains exactly.
        var quantity = try #require(observation["valueQuantity"] as? [String: Any])
        quantity["value"] = try #require(Decimal(string: "71.3"))
        observation["valueQuantity"] = quantity
        change(&observation)
        entries[index]["resource"] = observation
        bundle["entry"] = entries
        return try JSONSerialization.data(withJSONObject: bundle, options: [.sortedKeys])
    }
}
