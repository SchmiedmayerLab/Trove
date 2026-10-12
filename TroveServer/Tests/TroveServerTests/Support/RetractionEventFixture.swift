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


enum RetractionEventFixture {
    /// Synthetic retraction using the pinned IG shape; production uses Grove's exporter.
    static func bytes(activeBytes: Data, sequence: UInt64 = 43) throws -> Data {
        let active = try ExchangeGraph(validating: activeBytes, kind: .active)
        let entries = try #require(active.bundle.entry)
        let observations = entries.compactMap { entry -> Observation? in
            if case .observation(let observation)? = entry.resource { observation } else { nil }
        }
        let observation = try #require(observations.first)
        let identifiers = try (observation.identifier ?? []).map(RoledIdentifier.init)
        let record = try #require(identifiers.first { $0.role == .sourceRecord })
        let output = try #require(identifiers.first { $0.role == .sourceOutput })
        let event = try ExchangeEventIdentifier(
            system: active.event.system, producerInstance: active.eventIdentifier.producerInstance, sequence: EventSequence(sequence)
        )
        let keys = try entries.flatMap { $0.extension ?? [] }.compactMap { value -> RoledIdentifier? in
            guard value.url == Canonicals.entryNodeKey, case .identifier(let identifier)? = value.value else {
                return nil
            }
            return try RoledIdentifier(identifier)
        }
        let nodeSystem = try #require(keys.first { $0.role == .entryNode }).identifier.system
        let deviceSystem = try #require(keys.first { $0.role == .deviceSnapshot }).identifier.system
        let device = try FixtureIdentity.opaque(
            system: deviceSystem,
            role: .deviceSnapshot,
            components: [event.identifier.identifier.system.rawValue, event.identifier.identifier.value, "application", "fixture-app"]
        )
        let recorded = try Instant(date: Date(timeIntervalSince1970: 1_787_299_201))
        let provenance = provenance(record: record, output: output, device: device, recorded: recorded)
        let key = try FixtureIdentity.node(system: nodeSystem, event: event, role: "retraction-provenance", ordinal: "0")
        let entry = BundleEntry(
            extension: [.init(url: Canonicals.entryNodeKey, value: .identifier(key.fhirIdentifier))],
            fullUrl: try key.fullURL,
            resource: .provenance(provenance)
        )
        let bundle = ModelsR4.Bundle(
            entry: [entry],
            identifier: event.identifier.fhirIdentifier,
            meta: .init(profile: [Profile.groveMobileRetractionBundle]),
            timestamp: .init(recorded),
            type: .init(.collection)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try ExchangeGraph(validating: encoder.encode(bundle), kind: .retraction).json
    }

    private static func provenance(
        record: RoledIdentifier, output: RoledIdentifier, device: RoledIdentifier, recorded: Instant
    ) -> Provenance {
        Provenance(
            activity: .init(coding: [.init(code: "source-record-retracted", system: Canonicals.lifecycleEventCodeSystem)]),
            agent: [
                .init(
                    type: .init(coding: [.init(code: "assembler", system: Canonicals.provenanceParticipantType)]),
                    who: .init(identifier: device.fhirIdentifier, type: "Device")
                )
            ],
            entity: [.init(role: .init(.source), what: .init(identifier: record.fhirIdentifier))],
            meta: .init(profile: [Profile.groveMobileRetractionProvenance]),
            occurred: .period(.init(end: "2026-08-21T08:00:00Z")),
            recorded: .init(recorded),
            target: [
                .init(
                    extension: [.init(url: Canonicals.retractionTargetRole, value: .code("primary-output"))],
                    identifier: output.fhirIdentifier,
                    type: "Observation"
                )
            ]
        )
    }
}
