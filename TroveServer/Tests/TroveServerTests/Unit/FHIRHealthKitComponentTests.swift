// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import TroveServer


struct FHIRHealthKitComponentTests {
    private static let fixtures = [
        "heart-rate-motion-context", "high-heart-rate-threshold", "walking-steadiness-notification", "state-of-mind", "insulin-delivery-bolus"
    ]

    private static func bytes(_ name: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "HealthKitComponentEvents")))
    }

    /// Exact Grove producer records exercise receiver support; this is not a substitute for official IG validation.
    @Test(arguments: fixtures)
    func existingProducerComponentsRemainInCustodyWithoutReplacingThePrimaryValue(fixture: String) throws {
        let bytes = try Self.bytes(fixture)
        let projected = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "synthetic-component-receiver")
        #expect(projected.rawBytes == bytes && projected.outputs.count == 1)
        let source = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let entries = try #require(source["entry"] as? [[String: Any]])
        let resources = entries.compactMap { $0["resource"] as? [String: Any] }
        let observation = try #require(resources.first { $0["resourceType"] as? String == "Observation" })
        #expect((observation["component"] as? [Any])?.isEmpty == false)
        #expect(projected.outputs.first?.value != .components)
    }

    @Test(arguments: ["undeclared-code", "wrong-unit", "reference-value"])
    func componentSupportDoesNotAdmitUnknownMembersOrGraphReferences(corruption: String) throws {
        var bundle = try #require(JSONSerialization.jsonObject(with: Self.bytes("high-heart-rate-threshold")) as? [String: Any])
        var entries = try #require(bundle["entry"] as? [[String: Any]])
        let index = try #require(entries.firstIndex { ($0["resource"] as? [String: Any])?["resourceType"] as? String == "Observation" })
        var observation = try #require(entries[index]["resource"] as? [String: Any])
        var components = try #require(observation["component"] as? [[String: Any]])
        switch corruption {
        case "undeclared-code": components[0]["code"] = ["coding": [["system": "https://example.test/unknown", "code": "unknown"]]]
        case "wrong-unit": components[0]["valueQuantity"] = ["value": 120, "system": "http://unitsofmeasure.org", "code": "kg"]
        case "reference-value":
            components[0].removeValue(forKey: "valueQuantity")
            components[0]["valueReference"] = ["reference": "Patient/other"]
        default: break
        }
        observation["component"] = components
        entries[index]["resource"] = observation
        bundle["entry"] = entries
        #expect(throws: (any Error).self) {
            try FHIRPointProjection.project(
                validatedBytes: JSONSerialization.data(withJSONObject: bundle), validatorIdentity: "synthetic-component-receiver"
            )
        }
    }
}
