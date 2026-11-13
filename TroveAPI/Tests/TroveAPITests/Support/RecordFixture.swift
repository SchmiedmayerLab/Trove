//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import GroveFHIRContract
import Testing


enum RecordFixture {
    /// The Grove 0.3.0-beta.11 minimal heart-rate record with synthetic test identities.
    /// These test values exercise graph shape and custody, not keyed producer-conformance verification.
    static func make(sourceID: UUID, registrationID: UUID, seed: String, note: String? = nil, sourceSeed: String? = nil) throws -> ExchangeRecord {
        let url = try #require(Bundle.module.url(forResource: "record-heart-rate", withExtension: "json"))
        let original = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let keyID = registrationID.uuidString.lowercased()
        let digest = Data(SHA256.hash(data: Data(seed.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var bundle = try #require(mapStrings(original) { value in
            let prefix = "https://grovealliance.org/fhir/testing/identifiers/healthkit/"
            if value.hasPrefix(prefix) {
                let role = value.dropFirst(prefix.count).split(separator: "/")[0]
                return DeliveryFixture.identifierRoot(sourceID) + "/NamingSystem/grove-\(role)-v0/\(keyID)/1"
            }
            return value.replacingOccurrences(of: "v0:test:1:", with: "v0:\(keyID):1:")
        } as? [String: Any])
        var entries = try #require(bundle["entry"] as? [[String: Any]])
        let index = try #require(entries.firstIndex { ($0["resource"] as? [String: Any])?["resourceType"] as? String == "Provenance" })
        let extensions = try #require(entries[index]["extension"] as? [[String: Any]])
        let identifier = try #require(extensions.first?["valueIdentifier"] as? [String: Any])
        let oldVersion = try #require(identifier["value"] as? String)
        entries = try #require(mapStrings(entries) { $0 == oldVersion ? "v0:\(keyID):1:\(digest)" : $0 } as? [[String: Any]])
        if let sourceSeed { entries = try distinctSource(entries, seed: sourceSeed, keyID: keyID) }
        var addresses: [String: String] = [:]
        for entry in entries {
            let oldAddress = try #require(entry["fullUrl"] as? String)
            let key = try #require((entry["extension"] as? [[String: Any]])?.first?["valueIdentifier"] as? [String: Any])
            let identity = try BusinessIdentifier(
                system: IdentifierSystem(#require(key["system"] as? String)), value: #require(key["value"] as? String)
            )
            addresses[oldAddress] = try #require(identity.fullURL.value?.url.absoluteString)
        }
        if let note {
            let outputIndex = try #require(entries.firstIndex { ($0["resource"] as? [String: Any])?["resourceType"] as? String == "Observation" })
            var resource = try #require(entries[outputIndex]["resource"] as? [String: Any])
            resource["note"] = [["text": note]]
            entries[outputIndex]["resource"] = resource
        }
        bundle["entry"] = mapStrings(entries) { addresses[$0] ?? $0 }
        return try ExchangeRecord(validating: JSONSerialization.data(withJSONObject: bundle))
    }

    private static func distinctSource(_ entries: [[String: Any]], seed: String, keyID: String) throws -> [[String: Any]] {
        let outputs = entries.compactMap { $0["resource"] as? [String: Any] }
        let output = try #require(outputs.first { $0["resourceType"] as? String == "Observation" })
        var replacements: [String: String] = [:]
        for identifier in try #require(output["identifier"] as? [[String: Any]]) {
            let coding = (identifier["type"] as? [String: Any])?["coding"] as? [[String: Any]]
            guard let role = coding?.first?["code"] as? String, ["source-record", "source-output"].contains(role) else { continue }
            let old = try #require(identifier["value"] as? String)
            let value = Data(SHA256.hash(data: Data("\(seed):\(role)".utf8))).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            replacements[old] = "v0:\(keyID):1:\(value)"
        }
        return try #require(mapStrings(entries) { replacements[$0] ?? $0 } as? [[String: Any]])
    }

    private static func mapStrings(_ value: Any, transform: (String) throws -> String) rethrows -> Any {
        if let value = value as? String {
            return try transform(value)
        }
        if let values = value as? [Any] {
            return try values.map { try mapStrings($0, transform: transform) }
        }
        if let values = value as? [String: Any] {
            return try values.mapValues { try mapStrings($0, transform: transform) }
        }
        return value
    }
}
