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


/// Local boundary tests use the shared Swift identity constructors, without an external validator installation.
/// Full-validator tests retain ImmutablePointEventFixture and the independently pinned IG implementation.
enum LocalPointEventFixture {
    static func bytes(source: SourceBinding, sequence: UInt64 = 50, recordID: String? = nil) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "ImmutablePointEvent", withExtension: "json"))
        let original = try Data(contentsOf: url)
        let previous = try ExchangeGraph(kind: .active, jsonData: original)
        let event = try ExchangeEventIdentifier(
            system: IdentifierSystem(source.eventIdentifierSystem), producerInstance: source.producerInstance, sequence: sequence
        )
        var document = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var entries = try #require(document["entry"] as? [[String: Any]])
        var replacements = try recordID.map { try recordReplacements(in: previous, source: source, recordID: $0) } ?? [:]
        for index in entries.indices {
            var extensions = try #require(entries[index]["extension"] as? [[String: Any]])
            try #require(extensions.count == 1)
            let identifierJSON = try #require(extensions[0]["valueIdentifier"])
            let key = try BusinessIdentifier(JSONDecoder().decode(Identifier.self, from: JSONSerialization.data(withJSONObject: identifierJSON)))
            let newKey: BusinessIdentifier
            switch key.role {
            case .entryNode:
                let node = try ExchangeNodeKey(key, eventIdentifier: previous.eventIdentifier)
                newKey = try ExchangeNodeKey(system: key.system, eventIdentifier: event, nodeRole: node.nodeRole, ordinal: node.ordinal).identifier
            case .deviceSnapshot:
                newKey = try identityScope().deviceSnapshot(eventIdentifier: event, deviceRole: .application, sourceDeviceToken: "fixture-app")
                var resource = try #require(entries[index]["resource"] as? [String: Any])
                resource["identifier"] = [try object(newKey.fhirIdentifier)]
                entries[index]["resource"] = resource
            default:
                newKey = try BusinessIdentifier(system: key.system, value: replacements[key.value] ?? key.value, role: key.role)
            }
            let oldURL = try #require(entries[index]["fullUrl"] as? String)
            let newURL = try ExchangeIdentity.fullURL(for: newKey)
            replacements[oldURL] = newURL
            entries[index]["fullUrl"] = newURL
            extensions[0]["valueIdentifier"] = try object(newKey.fhirIdentifier)
            entries[index]["extension"] = extensions
        }
        document["identifier"] = try object(event.businessIdentifier.fhirIdentifier)
        document["entry"] = entries
        replacements["https://study.example.org/fhir/identifiers/participant"] = source.participantIdentifierSystem
        replacements["participant-001"] = source.participantIdentifierValue
        let timestamp = try TroveDateTranscoder().encode(Date())
        let transformed = transform(document, replacements: replacements, timestamp: timestamp)
        let bytes = try JSONSerialization.data(withJSONObject: transformed, options: [.sortedKeys, .withoutEscapingSlashes])
        _ = try ExchangeGraph(kind: .active, jsonData: bytes)
        return bytes
    }

    private static func object(_ identifier: Identifier) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(identifier))
    }

    /// Separate native records must have separate logical identities; event sequence alone
    /// cannot turn an unversioned update into another measurement or choose a current winner.
    private static func recordReplacements(in graph: ExchangeGraph, source: SourceBinding, recordID: String) throws -> [String: String] {
        let observations = (graph.bundle.entry ?? []).compactMap { entry -> Observation? in
            guard case .observation(let value)? = entry.resource else {
                return nil
            }
            return value
        }
        let observation = try #require(observations.first)
        let identifiers = try (observation.identifier ?? []).map(BusinessIdentifier.init)
        let record = try #require(identifiers.first { $0.role == .sourceRecord })
        let output = try #require(identifiers.first { $0.role == .sourceOutput })
        let privacy = try identityScope(sourceRecord: record.system, sourceOutput: output.system)
        let repository = try BusinessIdentifier(system: "https://fixture.trove.test/repository", value: source.id.uuidString.lowercased())
        let newRecord = try privacy.sourceRecord(
            adapterID: "synthetic", sourceType: "heart-rate", repositoryScope: repository, nativeRecordID: recordID
        )
        let newOutput = try privacy.sourceOutput(
            adapterID: "synthetic",
            sourceType: "heart-rate",
            repositoryScope: repository,
            nativeRecordID: recordID,
            outputRole: "primary",
            outputDiscriminator: "heart-rate"
        )
        return [record.value: newRecord.value, output.value: newOutput.value]
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

    private static func identityScope(
        sourceRecord: IdentifierSystem? = nil, sourceOutput: IdentifierSystem? = nil
    ) throws -> PseudonymousIdentityScope {
        let systems = try PseudonymousIdentitySystems(
            sourceRecord: sourceRecord ?? IdentifierSystem("https://fixture.trove.test/source-record"),
            sourceOutput: sourceOutput ?? IdentifierSystem("https://fixture.trove.test/source-output"),
            writerRecord: IdentifierSystem("https://fixture.trove.test/writer-record"),
            providerRecord: IdentifierSystem("https://fixture.trove.test/provider-record"),
            providerOutput: IdentifierSystem("https://fixture.trove.test/provider-output"),
            sourceArtifact: IdentifierSystem("https://fixture.trove.test/source-artifact"),
            providerArtifact: IdentifierSystem("https://fixture.trove.test/provider-artifact"),
            sourceContext: IdentifierSystem("https://fixture.trove.test/source-context"),
            recordingDevice: IdentifierSystem("https://fixture.trove.test/recording-device"),
            deviceSnapshot: IdentifierSystem("https://fixture.trove.test/device-snapshot")
        )
        return try .init(systems: systems, keyID: "local-test", epoch: UInt64(1), key: Data(repeating: 0xA5, count: 32))
    }
}
