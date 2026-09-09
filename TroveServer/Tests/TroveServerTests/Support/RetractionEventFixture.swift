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
    /// Uses the shared Grove producer, retaining the active graph's complete logical identities.
    static func bytes(activeBytes: Data, sequence: UInt64 = 43) throws -> Data {
        let active = try ExchangeGraph(kind: .active, jsonData: activeBytes)
        let entries = try #require(active.bundle.entry)
        let observations = entries.compactMap { entry -> Observation? in
            guard case .observation(let observation)? = entry.resource else {
                return nil
            }
            return observation
        }
        let observation = try #require(observations.first)
        let identifiers = try (observation.identifier ?? []).map(BusinessIdentifier.init)
        let record = try #require(identifiers.first { $0.role == .sourceRecord })
        let output = try #require(identifiers.first { $0.role == .sourceOutput })
        let devices = entries.compactMap { entry -> Device? in
            guard case .device(let device)? = entry.resource else {
                return nil
            }
            return device
        }
        let device = try #require(devices.first)
        let deviceID = try #require(try (device.identifier ?? []).map(BusinessIdentifier.init).first { $0.role == .deviceSnapshot })
        let graph = try RetractionEventBuilder.build(
            targets: [.init(identifier: output, resourceType: .observation, role: .primaryOutput)],
            context: .init(
                eventIdentifier: .init(
                    system: IdentifierSystem(active.eventIdentifier.businessIdentifier.systemValue),
                    producerInstance: active.eventIdentifier.producerInstance,
                    sequence: sequence
                ),
                entryNodeIdentifierSystem: entryNodeSystem(in: entries),
                producer: Reference(identifier: deviceID.fhirIdentifier, type: "Device"),
                sourceRecord: record,
                occurred: .period(.init(end: .init(try DateTime(date: Date(timeIntervalSince1970: 1_787_299_200))))),
                recordedAt: Date(timeIntervalSince1970: 1_787_299_201)
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(graph.bundle)
    }

    private static func entryNodeSystem(in entries: [BundleEntry]) throws -> IdentifierSystem {
        let keys = try entries.flatMap { $0.extension ?? [] }.compactMap { value -> BusinessIdentifier? in
            guard value.url == Canonicals.entryNodeKey, case .identifier(let identifier)? = value.value else {
                return nil
            }
            return try BusinessIdentifier(identifier)
        }
        return try #require(keys.first { $0.role == .entryNode }).system
    }
}
