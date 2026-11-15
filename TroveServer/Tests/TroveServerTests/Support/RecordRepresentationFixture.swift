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


/// Synthetic context keys exercise receiver boundaries; full-IG identity tests use the pinned generator.
enum RecordRepresentationFixture {
    static func enrollment(_ bytes: Data, status: String = "off-study", rekey: Bool = true) throws -> Data {
        var document = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var entries = try #require(document["entry"] as? [[String: Any]])
        let index = try #require(entries.firstIndex { ($0["resource"] as? [String: Any])?["resourceType"] as? String == "ResearchSubject" })
        var resource = try #require(entries[index]["resource"] as? [String: Any])
        resource["status"] = status
        if rekey {
            var extensions = try #require(entries[index]["extension"] as? [[String: Any]])
            let original = try RoledIdentifier(JSONDecoder().decode(
                Identifier.self, from: JSONSerialization.data(withJSONObject: #require(extensions[0]["valueIdentifier"]))
            ))
            let key = try FixtureIdentity.opaque(
                system: original.identifier.system, role: .contextSnapshot, components: [original.identifier.value, status]
            )
            let encodedKey = try JSONSerialization.jsonObject(with: JSONEncoder().encode(key.fhirIdentifier))
            extensions[0]["valueIdentifier"] = encodedKey
            var identifiers = try #require(resource["identifier"] as? [[String: Any]])
            let identityIndex = try #require(identifiers.firstIndex {
                $0["system"] as? String == original.identifier.system.rawValue && $0["value"] as? String == original.identifier.value
            })
            identifiers[identityIndex] = try #require(encodedKey as? [String: Any])
            resource["identifier"] = identifiers
            entries[index]["extension"] = extensions
            entries[index]["fullUrl"] = try #require(key.fullURL.value?.url.absoluteString)
        }
        entries[index]["resource"] = resource
        document["entry"] = entries
        return try ExchangeRecord(validating: JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])).json
    }
}
