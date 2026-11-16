//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import TroveServer


/// Grove's golden records that disclose a readable sync identifier beside the native UUID, copied unchanged from the
/// pinned Grove revision.
enum SyncIdentifierFixture {
    static let nativeSystem = "https://grovealliance.org/fhir/testing/identifiers/native-healthkit-record"
    static let system = nativeSystem + "/" + FHIRSyncRecordIdentifier.systemPathSegment + "/org.example.writer"
    static let value = "sync-abc"

    static func url(_ name: String = "sync-identifier-disclosure") throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "HealthKitComponentEvents"))
    }

    static func bytes(_ name: String = "sync-identifier-disclosure") throws -> Data {
        try Data(contentsOf: url(name))
    }

    /// Applies `change` to the first resource of `resourceType` and returns the re-encoded record.
    static func changing(
        _ bytes: Data, resourceType: String = "Observation", _ change: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        var document = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var entries = try #require(document["entry"] as? [[String: Any]])
        let index = try #require(entries.firstIndex { ($0["resource"] as? [String: Any])?["resourceType"] as? String == resourceType })
        var resource = try #require(entries[index]["resource"] as? [String: Any])
        try change(&resource)
        entries[index]["resource"] = resource
        document["entry"] = entries
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Applies `change` to the sync identifier of the record's Observation.
    static func changingSyncIdentifier(_ bytes: Data, _ change: @escaping (inout [String: Any]) -> Void) throws -> Data {
        try changing(bytes) { resource in
            var identifiers = try #require(resource["identifier"] as? [[String: Any]])
            let index = try #require(identifiers.firstIndex(where: isSyncIdentifier))
            change(&identifiers[index])
            resource["identifier"] = identifiers
        }
    }

    static func isSyncIdentifier(_ identifier: [String: Any]) -> Bool {
        let codings = (identifier["type"] as? [String: Any])?["coding"] as? [[String: Any]] ?? []
        return codings.contains { $0["code"] as? String == FHIRSyncRecordIdentifier.typeCode }
    }
}
