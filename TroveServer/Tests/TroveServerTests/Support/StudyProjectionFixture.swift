//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import ModelsR4
import Testing
@testable import TroveServer


/// Synthetic graph-shape fixtures for derived views, not official IG admission evidence.
enum StudyProjectionFixture {
    static let decimal = "73.12345678901234567890123456789"
    static let writerVersion = "9007199254740992"
    static let writerValue = "v0:test-key:1:TN39cF6jcCICy4SlWBjpAulk4eMlcb-KM3MwESD9cvw"
    static let note = "Original wording: \"quoted\", backslash \\, unicode e\u{301} and 雪."

    static func subject(_ value: String = "enrollment-a") throws -> BusinessIdentifier {
        try .init(system: IdentifierSystem("https://trove.example/study-participants/study-a"), value: value)
    }

    static func event(healthKit: Bool = true, additionalOutput: Bool = false) throws -> ValidatedExchangeEvent {
        let name = healthKit ? "HealthKitPointEvent" : "ImmutablePointEvent"
        let url = try #require(Foundation.Bundle.module.url(forResource: name, withExtension: "json"))
        let bytes = try Data(contentsOf: url)
        var document = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var entries = try #require(document["entry"] as? [[String: Any]])
        let index = try #require(entries.firstIndex { ($0["resource"] as? [String: Any])?["resourceType"] as? String == "Observation" })
        var observation = try #require(entries[index]["resource"] as? [String: Any])
        try enrich(&observation, native: healthKit)
        entries[index]["resource"] = observation
        if additionalOutput { try appendOutput(to: &entries, observationIndex: index) }
        for index in entries.indices {
            var resource = try #require(entries[index]["resource"] as? [String: Any])
            var meta = resource["meta"] as? [String: Any] ?? [:]
            meta["source"] = "https://other-study.example/source"
            meta["tag"] = [["system": "https://other-study.example/tags", "code": "OTHER-STUDY"]]
            meta["security"] = [["system": "http://terminology.hl7.org/CodeSystem/v3-Confidentiality", "code": "R"]]
            resource["meta"] = meta
            if resource["resourceType"] as? String == "Provenance" {
                resource["policy"] = ["https://other-study.example/policy"]
                resource["reason"] = [["text": "OTHER-STUDY-PURPOSE"]]
            }
            entries[index]["resource"] = resource
        }
        document["entry"] = entries
        let encoded = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
        let text = String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "\"value\":73", with: "\"value\":" + decimal)
        let enriched = Data(text.utf8)
        _ = try ExchangeRecord(validating: enriched)
        return try FHIRPointProjection.project(validatedBytes: enriched, validatorIdentity: "projection-unit-fixture")
    }

    static func entries(_ result: StudyPointProjection.Result) throws -> [[String: Any]] {
        let bundle = try #require(JSONSerialization.jsonObject(with: result.json) as? [String: Any])
        return try #require(bundle["entry"] as? [[String: Any]])
    }

    static func resources(_ result: StudyPointProjection.Result, type: String) throws -> [[String: Any]] {
        try entries(result).compactMap { $0["resource"] as? [String: Any] }.filter { $0["resourceType"] as? String == type }
    }

    private static func enrich(_ observation: inout [String: Any], native: Bool) throws {
        var identifiers = try #require(observation["identifier"] as? [[String: Any]])
        if native { identifiers.append(["system": NativeIdentifierFixture.system, "value": NativeIdentifierFixture.uuid]) }
        identifiers.append([
            "system": "https://study.example.org/fhir/NamingSystem/grove-writer-record-v0/test-key/1", "value": writerValue,
            "type": ["coding": [["system": Canonicals.root + "/mobile/CodeSystem/grove-identifier-role", "code": "writer-record"]]]
        ])
        observation["identifier"] = identifiers
        var extensions = try #require(observation["extension"] as? [[String: Any]])
        extensions.append(["url": Canonicals.root + "/mobile/StructureDefinition/grove-writer-record-version", "valueString": writerVersion])
        observation["extension"] = extensions
        observation["note"] = [["text": note, "authorString": "Synthetic source author"]]
        observation["text"] = ["status": "generated", "div": "<div xmlns=\"http://www.w3.org/1999/xhtml\">UNFILTERED-NARRATIVE</div>"]
        var quantity = try #require(observation["valueQuantity"] as? [String: Any])
        quantity["value"] = 73
        observation["valueQuantity"] = quantity
    }

    private static func appendOutput(to entries: inout [[String: Any]], observationIndex: Int) throws {
        var extra = entries[observationIndex]
        let outputAddress = try replaceKey(in: &extra, role: .sourceOutput, discriminator: "extra-output")
        var observation = try #require(extra["resource"] as? [String: Any])
        // Native UUID belongs to the catalog-designated primary output only.
        let identifiers = try #require(observation["identifier"] as? [[String: Any]])
        observation["identifier"] = identifiers.filter { $0["system"] as? String != NativeIdentifierFixture.system }
        observation["note"] = [["text": "UNSELECTED-OUTPUT"]]
        let deviceIndex = try #require(entries.firstIndex { ($0["resource"] as? [String: Any])?["resourceType"] as? String == "Device" })
        var device = entries[deviceIndex]
        let deviceAddress = try replaceKey(in: &device, role: .deviceSnapshot, discriminator: "extra-device")
        var deviceResource = try #require(device["resource"] as? [String: Any])
        deviceResource["modelNumber"] = "UNSELECTED-DEVICE"
        device["resource"] = deviceResource
        var extensions = try #require(observation["extension"] as? [[String: Any]])
        extensions.append([
            "url": "http://hl7.org/fhir/StructureDefinition/observation-gatewayDevice", "valueReference": ["reference": deviceAddress]
        ])
        observation["extension"] = extensions
        extra["resource"] = observation
        entries.append(contentsOf: [extra, device])
        let provenanceIndex = try #require(entries.firstIndex { ($0["resource"] as? [String: Any])?["resourceType"] as? String == "Provenance" })
        var provenance = try #require(entries[provenanceIndex]["resource"] as? [String: Any])
        var targets = try #require(provenance["target"] as? [[String: Any]])
        targets.append(["reference": outputAddress])
        provenance["target"] = targets
        entries[provenanceIndex]["resource"] = provenance
    }

    private static func replaceKey(in entry: inout [String: Any], role: GroveIdentifierRole, discriminator: String) throws -> String {
        var resource = try #require(entry["resource"] as? [String: Any])
        var identifiers = try #require(resource["identifier"] as? [[String: Any]])
        let index = try #require(identifiers.firstIndex { value in
            let coding = (value["type"] as? [String: Any])?["coding"] as? [[String: Any]]
            return coding?.contains { $0["code"] as? String == role.rawValue } == true
        })
        let system = try IdentifierSystem(#require(identifiers[index]["system"] as? String))
        let key = try FixtureIdentity.opaque(system: system, role: role, components: [discriminator])
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(key.fhirIdentifier)) as? [String: Any])
        identifiers[index] = json
        resource["identifier"] = identifiers
        entry["resource"] = resource
        let address = try #require(key.fullURL.value?.url.absoluteString)
        entry["fullUrl"] = address
        entry["extension"] = [["url": Canonicals.root + "/mobile/StructureDefinition/grove-exchange-entry-key", "valueIdentifier": json]]
        return address
    }
}
