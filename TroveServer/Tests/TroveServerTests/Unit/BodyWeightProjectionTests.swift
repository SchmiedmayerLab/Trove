// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import TroveAPITypes
@testable import TroveServer


struct BodyWeightProjectionTests {
    @Test
    func bodyWeightProjectionPreservesExactDecimalTokensAndItsPointTimestamp() throws {
        let text = try String(decoding: bytes(), as: UTF8.self)
        try #require(text.contains("71.3"))
        let exact = "71.300000000000000000001"
        let changed = Data(text.replacingOccurrences(of: "71.3", with: exact).utf8)
        let event = try FHIRPointProjection.project(validatedBytes: changed, validatorIdentity: "synthetic-decimal-projection")
        let output = try #require(event.outputs.first)
        #expect(output.profile == CollectionObservationProfile.bodyWeight.rawValue)
        #expect(output.value.quantityValue == exact && output.value.quantityCode == "kg")
        #expect(output.effectiveEnd == nil)
        #expect(event.rawBytes == changed)
    }

    @Test(arguments: ["unknown-profile", "period"])
    func addedScalarCapabilityDoesNotAdmitOtherProfilesOrTemporalShapes(change: String) throws {
        var object = try #require(JSONSerialization.jsonObject(with: bytes()) as? [String: Any])
        var entries = try #require(object["entry"] as? [[String: Any]])
        let index = try #require(entries.firstIndex { ($0["resource"] as? [String: Any])?["resourceType"] as? String == "Observation" })
        var observation = try #require(entries[index]["resource"] as? [String: Any])
        if change == "period" {
            let removed = observation.removeValue(forKey: "effectiveDateTime")
            let instant = try #require(removed)
            observation["effectivePeriod"] = ["start": instant, "end": instant]
        } else {
            observation["meta"] = ["profile": ["https://grovealliance.org/fhir/mobile/StructureDefinition/grove-mobile-unknown-measurement"]]
        }
        entries[index]["resource"] = observation
        object["entry"] = entries
        #expect(throws: (any Error).self) {
            try FHIRPointProjection.project(
                validatedBytes: JSONSerialization.data(withJSONObject: object), validatorIdentity: "synthetic-capability-boundary"
            )
        }
    }

    private func bytes() throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: "HealthKitBodyWeightEvent", withExtension: "json")))
    }
}
