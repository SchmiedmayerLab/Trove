//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing


/// Synthetic receiver-boundary fixture, not a newly captured HealthKit conversion or full-validator result.
enum NativeIdentifierFixture {
    static let uuid = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    static let system = "https://study.example.org/fhir/NamingSystem/healthkit-native-record"

    static func healthKitURL() throws -> URL {
        try #require(Bundle.module.url(forResource: "HealthKitPointEvent", withExtension: "json"))
    }

    static func adding(_ identifiers: [[String: Any]], to bytes: Data, resourceType: String = "Observation") throws -> Data {
        var document = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var entries = try #require(document["entry"] as? [[String: Any]])
        let index = try #require(entries.firstIndex { ($0["resource"] as? [String: Any])?["resourceType"] as? String == resourceType })
        var resource = try #require(entries[index]["resource"] as? [String: Any])
        let existing = try #require(resource["identifier"] as? [[String: Any]])
        resource["identifier"] = existing + identifiers
        entries[index]["resource"] = resource
        document["entry"] = entries
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
