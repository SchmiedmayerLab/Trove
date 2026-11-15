//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

#if canImport(HealthKit)

import Foundation
import GroveFHIRContract
import GroveHealthKitFHIR
import HealthKit
import Testing
@testable import TroveAPIClient
@testable import TroveHealthKit


struct HealthKitExporterConfigurationTests {
    private static let start = Date(timeIntervalSince1970: 1_787_000_000)

    @Test
    func exporterPreservesAllSourceMetadata() async throws {
        try await Self.withExporterInputs { source, privacy in
            let exporter = try Self.exporter(source: source, privacy: privacy)
            let sample = HKQuantitySample(
                type: HKQuantityType(.heartRate),
                quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: 72),
                start: Self.start,
                end: Self.start,
                metadata: [
                    HKMetadataKeyTimeZone: "UTC",
                    HKMetadataKeyExternalUUID: "external-1",
                    HKMetadataKeyDeviceSerialNumber: "serial-1",
                    "org.trove.test.note": "custom"
                ]
            )
            var exports: [HealthKitFHIRExporter.Export] = []
            try await exporter.export([sample], at: Self.start) { exports.append($0) }
            let export = try #require(exports.first)
            let metadata = try #require(export.metadata)
            // The external UUID, an identifying key, and the custom key reach the metadata extension; the recording
            // Device states the serial number under every policy. A narrower policy would exclude the external UUID.
            #expect(metadata.preservedSampleKeys == 2)
            #expect(metadata.excludedSampleKeys == 0)
            let record = try #require(export.record)
            let json = String(decoding: record.json, as: UTF8.self)
            for value in [HKMetadataKeyExternalUUID, "external-1", "serial-1", "org.trove.test.note", "custom"] {
                #expect(json.contains(value))
            }
        }
    }

    /// Grove derives the readable sync identifier's system from the native one, so the native system must name an
    /// authority. The server roots every source under its issuer URL; a root without an authority is refused.
    @Test
    func exporterRefusesAnIdentifierRootWithoutAuthority() async throws {
        try await Self.withExporterInputs(identifierRoot: "urn:uuid:19e5294b-859b-4670-8c58-9f34f5417cd1") { source, privacy in
            #expect(throws: HealthKitFHIRExporter.ConfigurationError.self) {
                try Self.exporter(source: source, privacy: privacy)
            }
        }
    }
}


extension HealthKitExporterConfigurationTests {
    private static func exporter(
        source: Components.Schemas.ParticipantSource, privacy: OpaqueIdentityScope
    ) throws -> HealthKitFHIRExporter {
        try HealthKitAcquisition.exporter(
            source: source,
            privacy: privacy,
            application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
            host: .init(operatingSystemVersion: "27.2")
        )
    }

    private static func withExporterInputs(
        identifierRoot: String? = nil,
        _ operation: (Components.Schemas.ParticipantSource, OpaqueIdentityScope) async throws -> Void
    ) async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let sourceID = UUID(), localID = UUID()
            let root = identifierRoot ?? DeliveryFixture.identifierRoot(sourceID)
            var binding = DeliveryFixture.binding(sourceID: sourceID, registrationID: localID)
            binding.source.identifierRoot = root
            binding.source.eventIdentifierSystem = root + "/NamingSystem/grove-record-version-v0/\(localID.uuidString.lowercased())/1"
            binding.source.repositoryScope.system = root + "/repository"
            let setup = try await journal.createSource(localID: localID, queryDefinition: HealthKitAcquisition.queryDefinition(start: start))
            try await journal.confirmSource(binding, for: setup, identityKey: DeliveryFixture.identityKey)
            try await operation(binding.source, journal.identityScope(for: sourceID))
        }
    }
}

#endif
