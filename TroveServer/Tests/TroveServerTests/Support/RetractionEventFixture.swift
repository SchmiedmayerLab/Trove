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
        let system = try IdentifierSystem(record.identifier.system.rawValue.replacingOccurrences(
            of: "grove-source-record-v0", with: "grove-record-retraction-v0"
        ))
        let key = try FixtureIdentity.opaque(
            system: system,
            role: .recordRetraction,
            components: [record.identifier.system.rawValue, record.identifier.value]
        )
        let devices = entries.filter {
            if case .device? = $0.resource { true } else { false }
        }
        let provenances = entries.compactMap { entry -> Provenance? in
            if case .provenance(let value)? = entry.resource { value } else { nil }
        }
        let conversion = try #require(provenances.first)
        let recorded = try Instant(date: Date(timeIntervalSince1970: 1_787_299_201 + Double(sequence)))
        let provenance = provenance(record: record, agents: conversion.agent, recorded: recorded)
        let entry = BundleEntry(
            extension: [.init(url: Canonicals.entryKey, value: .identifier(key.fhirIdentifier))],
            fullUrl: try key.fullURL,
            resource: .provenance(provenance)
        )
        let bundle = ModelsR4.Bundle(
            entry: [entry] + devices,
            meta: .init(profile: [Profile.groveMobileRetractionBundle]),
            timestamp: .init(recorded),
            type: .init(.collection)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try ExchangeRecord(validating: encoder.encode(bundle)).json
    }

    private static func provenance(
        record: RoledIdentifier, agents: [ProvenanceAgent], recorded: Instant
    ) -> Provenance {
        Provenance(
            activity: .init(coding: [.init(code: "source-record-retracted", system: Canonicals.lifecycleEventCodeSystem)]),
            agent: agents,
            entity: [.init(role: .init(.source), what: .init(identifier: record.fhirIdentifier))],
            meta: .init(profile: [Profile.groveMobileRetractionProvenance]),
            occurred: .period(.init(end: "2026-08-21T08:00:00Z")),
            recorded: .init(recorded),
            target: [
                .init(
                    extension: [.init(url: Canonicals.retractionTargetRole, value: .code("source-record"))],
                    identifier: record.fhirIdentifier
                )
            ]
        )
    }
}
