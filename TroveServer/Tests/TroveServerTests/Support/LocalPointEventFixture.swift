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
import TroveAPIServer
@testable import TroveServer


/// Local boundary tests use synthetic identities to exercise graph shape and custody.
/// These keys are not evidence of producer HMAC conformance.
/// Full-validator tests retain ImmutablePointEventFixture and the independently pinned IG implementation.
enum LocalPointEventFixture {
    static func bytes(source: SourceBinding, sequence: UInt64 = 50, recordID: String? = nil) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "ImmutablePointEvent", withExtension: "json"))
        let original = try Data(contentsOf: url)
        let previous = try ExchangeGraph(validating: original, kind: .active)
        var document = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var entries = try #require(document["entry"] as? [[String: Any]])
        var replacements = try recordID.map { try recordReplacements(in: previous, source: source, recordID: $0) } ?? [:]
        let systems = try SourceIdentityNamespaces.assign(root: source.identifierRoot, registrationID: source.registrationID)
        let identifiers = try JSONDecoder().decode(FHIRDeploymentIdentifiers.self, from: original)
        for (role, oldSystems) in identifiers.systems {
            for oldSystem in oldSystems {
                replacements[oldSystem] = FHIRDeploymentIdentifiers.system(for: role, in: systems).rawValue
            }
        }
        try rekeyEntries(&entries, sequence: sequence, systems: systems, replacements: &replacements)
        document["entry"] = entries
        replacements["https://study.example.org/fhir/identifiers/participant"] = source.participantIdentifierSystem
        replacements["participant-001"] = source.participantIdentifierValue
        let timestamp = try TroveDateTranscoder().encode(Date())
        let transformed = transform(document, replacements: replacements, timestamp: timestamp)
        let bytes = try JSONSerialization.data(withJSONObject: transformed, options: [.sortedKeys, .withoutEscapingSlashes])
        return try ExchangeRecord(validating: bytes).json
    }

    private static func rekeyEntries(
        _ entries: inout [[String: Any]],
        sequence: UInt64,
        systems: DeploymentIdentifierSystems,
        replacements: inout [String: String]
    ) throws {
        for index in entries.indices {
            var extensions = try #require(entries[index]["extension"] as? [[String: Any]])
            try #require(extensions.count == 1)
            let identifierJSON = try #require(extensions[0]["valueIdentifier"])
            let originalKey = try RoledIdentifier(JSONDecoder().decode(Identifier.self, from: JSONSerialization.data(withJSONObject: identifierJSON)))
            let key = RoledIdentifier(identifier: try BusinessIdentifier(
                system: FHIRDeploymentIdentifiers.system(for: originalKey.role, in: systems), value: originalKey.identifier.value
            ), role: originalKey.role)
            let newKey: RoledIdentifier
            switch key.role {
            case .contextSnapshot, .deviceSnapshot, .recordVersion:
                newKey = try FixtureIdentity.opaque(
                    system: key.identifier.system,
                    role: key.role,
                    components: [key.identifier.system.rawValue, key.identifier.value, String(sequence)]
                )
                replacements[originalKey.identifier.value] = newKey.identifier.value
            default:
                newKey = .init(
                    identifier: try BusinessIdentifier(
                        system: key.identifier.system, value: replacements[key.identifier.value] ?? key.identifier.value
                    ), role: key.role
                )
            }
            let oldURL = try #require(entries[index]["fullUrl"] as? String)
            let newURL = try #require(newKey.fullURL.value?.url.absoluteString)
            replacements[oldURL] = newURL
            entries[index]["fullUrl"] = newURL
            extensions[0]["valueIdentifier"] = try object(newKey.fhirIdentifier)
            entries[index]["extension"] = extensions
        }
    }

    private static func object(_ identifier: Identifier) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(identifier))
    }

    /// Separate native records must have separate logical identities; a conversion revision alone
    /// cannot turn an unversioned update into another measurement or choose a current winner.
    private static func recordReplacements(in graph: ExchangeGraph, source: SourceBinding, recordID: String) throws -> [String: String] {
        let observations = (graph.bundle.entry ?? []).compactMap { entry -> Observation? in
            guard case .observation(let value)? = entry.resource else {
                return nil
            }
            return value
        }
        let observation = try #require(observations.first)
        let identifiers = try (observation.identifier ?? []).map(RoledIdentifier.init)
        let record = try #require(identifiers.first { $0.role == .sourceRecord })
        let output = try #require(identifiers.first { $0.role == .sourceOutput })
        let components = ["synthetic", "heart-rate", "https://fixture.trove.test/repository", source.id.uuidString.lowercased(), recordID]
        let newRecord = try FixtureIdentity.opaque(system: record.identifier.system, role: .sourceRecord, components: components)
        let newOutput = try FixtureIdentity.opaque(
            system: output.identifier.system, role: .sourceOutput, components: components + ["primary", "heart-rate"]
        )
        return [record.identifier.value: newRecord.identifier.value, output.identifier.value: newOutput.identifier.value]
    }

    private static func transform(_ value: Any, replacements: [String: String], timestamp: String) -> Any {
        if let object = value as? [String: Any] {
            var result = object.mapValues { transform($0, replacements: replacements, timestamp: timestamp) }
            for key in ["effectiveDateTime", "issued", "recorded", "timestamp", "authored"] where object[key] != nil {
                result[key] = timestamp
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { transform($0, replacements: replacements, timestamp: timestamp) }
        }
        if let string = value as? String {
            return replacements[string] ?? string
        }
        return value
    }
}
