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
    private enum FHIRFixtureError: Error { case unsupportedReference }

    /// Synthetic retraction using the pinned IG shape; production uses Grove's exporter.
    static func bytes(
        activeBytes: Data, sequence: UInt64 = 43, nativeIdentifier: Identifier? = nil, retractionSystem: IdentifierSystem? = nil
    ) throws -> Data {
        let active = try ExchangeGraph(validating: activeBytes, kind: .active)
        let entries = try #require(active.bundle.entry)
        let outputIdentifiers = entries.flatMap { entry -> [Identifier] in
            switch entry.resource {
            case .observation(let observation): observation.identifier ?? []
            case .documentReference(let document): document.identifier ?? []
            default: []
            }
        }
        let identifiers = try outputIdentifiers
            .filter { $0.type?.coding?.contains(where: { $0.system == Canonicals.identifierRoleCodeSystem }) == true }
            .map(RoledIdentifier.init)
        let record = try #require(identifiers.first { $0.role == .sourceRecord })
        let system = try retractionSystem ?? IdentifierSystem(record.identifier.system.rawValue.replacingOccurrences(
            of: "grove-source-record-v0", with: "grove-record-retraction-v0"
        ))
        let key = try FixtureIdentity.opaque(
            system: system,
            role: .recordRetraction,
            components: [record.identifier.system.rawValue, record.identifier.value]
        )
        let provenances = entries.compactMap { entry -> Provenance? in
            if case .provenance(let value)? = entry.resource { value } else { nil }
        }
        let conversion = try #require(provenances.first)
        let recorded = try Instant(date: Date(timeIntervalSince1970: 1_787_299_201 + Double(sequence)))
        let provenance = provenance(record: record, agents: conversion.agent, recorded: recorded, nativeIdentifier: nativeIdentifier)
        let devices = try supportingDevices(provenance, entries: entries)
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

    /// A retraction carries converter context only, not unrelated recording Devices from the active sample.
    private static func supportingDevices(_ provenance: Provenance, entries: [BundleEntry]) throws -> [BundleEntry] {
        func references(_ value: Any) -> [String] {
            if let object = value as? [String: Any] {
                return object.flatMap { key, child in key == "reference" ? (child as? String).map { [$0] } ?? [] : references(child) }
            }
            return (value as? [Any])?.flatMap(references) ?? []
        }
        var pending = try references(JSONSerialization.jsonObject(with: JSONEncoder().encode(provenance)))
        var visited: Set<String> = []
        while let address = pending.popLast() {
            guard visited.insert(address).inserted else { continue }
            let entry = try #require(entries.first { $0.fullUrl?.value?.url.absoluteString == address })
            guard case .device(let device)? = entry.resource else { throw FHIRFixtureError.unsupportedReference }
            pending += try references(JSONSerialization.jsonObject(with: JSONEncoder().encode(device)))
        }
        return entries.filter { entry in
            guard let address = entry.fullUrl?.value?.url.absoluteString else {
                return false
            }
            return visited.contains(address)
        }
    }

    private static func provenance(
        record: RoledIdentifier, agents: [ProvenanceAgent], recorded: Instant, nativeIdentifier: Identifier?
    ) -> Provenance {
        var extensions = [Extension(url: Canonicals.retractionTargetRole, value: .code("source-record"))]
        if let nativeIdentifier {
            extensions.append(.init(url: Canonicals.retractionTargetNativeIdentifier, value: .identifier(nativeIdentifier)))
        }
        return Provenance(
            activity: .init(coding: [.init(code: "source-record-retracted", system: Canonicals.lifecycleEventCodeSystem)]),
            agent: agents,
            entity: [.init(role: .init(.source), what: .init(identifier: record.fhirIdentifier))],
            meta: .init(profile: [Profile.groveMobileRetractionProvenance]),
            occurred: .period(.init(end: "2026-08-21T08:00:00Z")),
            recorded: .init(recorded),
            target: [
                .init(
                    extension: extensions,
                    identifier: record.fhirIdentifier
                )
            ]
        )
    }
}
