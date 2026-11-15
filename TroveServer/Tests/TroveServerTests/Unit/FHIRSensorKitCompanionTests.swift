//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveSensorKitFHIR
import ModelsR4
import Testing
@testable import TroveServer


struct FHIRSensorKitCompanionTests {
    @Test("A mandatory original remains in custody while each study receives only its selected output")
    func separatesCustodyFromStudyProjection() async throws {
        let bytes = try await fixtureBytes()
        let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "synthetic-receiver-test")
        try #require(event.outputs.count == 2)
        let summary = try #require(event.outputs.first { $0.value != .recording })
        let original = try #require(event.outputs.first { $0.value == .recording })
        #expect(summary.sourceRecordIdentifier == original.sourceRecordIdentifier)
        #expect(event.outputDependencies.contains {
            $0.outputFullURL == summary.fullURL && $0.targetFullURL == original.fullURL && $0.relation == .derivedFrom
        })
        #expect(throws: (any Error).self) { try FHIRSensorKitCompanions.validate([summary]) }
        #expect(throws: (any Error).self) { try FHIRSensorKitCompanions.validate([original]) }
        let view = try StudyPointProjection.project(
            event, outputs: [summary.fullURL], subject: .init(system: IdentifierSystem("https://example.test/study-subject"), value: "synthetic")
        )
        let bundle = try JSONDecoder().decode(ModelsR4.Bundle.self, from: view.json)
        #expect(bundle.entry?.contains { $0.resource?.resourceType == "DocumentReference" } == false)
        let observation = try #require(bundle.entry?.compactMap { $0.resource?.get() as? Observation }.first)
        let reference = try #require(observation.derivedFrom?.first)
        #expect(reference.reference == nil)
        let logical = try BusinessIdentifier(#require(reference.identifier))
        #expect(logical.system.rawValue == original.sourceOutputIdentifier.system)
        #expect(logical.value == original.sourceOutputIdentifier.value)
    }

    @Test(arguments: ["missing-related", "wrong-related", "missing-derived", "wrong-derived", "different-record"])
    func refusesUnboundHybridTiming(change: String) async throws {
        let bundle = try JSONDecoder().decode(ModelsR4.Bundle.self, from: await fixtureBytes())
        var (_, resources) = try FHIRPointProjection.index(#require(bundle.entry))
        let entry = try #require(bundle.entry?.first { $0.resource?.resourceType == "DocumentReference" })
        var document = try #require(entry.resource?.get() as? DocumentReference)
        var summary = try #require(bundle.entry?.compactMap { $0.resource?.get() as? Observation }.first)
        let fullURL = try #require(entry.fullUrl?.value?.url.absoluteString)
        switch change {
        case "missing-related": document.context?.related = nil
        case "wrong-related": document.context?.related = [Reference(reference: "urn:uuid:unrelated")]
        case "missing-derived": summary.derivedFrom = nil
        case "wrong-derived": summary.derivedFrom = [Reference(reference: "urn:uuid:unrelated")]
        default: summary.identifier = []
        }
        let summaryURL = try #require(bundle.entry?.first { $0.resource?.resourceType == "Observation" }?.fullUrl?.value?.url.absoluteString)
        resources[summaryURL] = .observation(summary)
        resources[fullURL] = .documentReference(document)
        #expect(throws: (any Error).self) {
            try FHIRSensorKitCompanions.relatedPeriod(document, fullURL: fullURL, resources: resources)
        }
    }

    private func fixtureBytes() async throws -> Data {
        let csv = Data(("timestamp,identifier,x,y,z,device\n1787009400,1,-0.1,0.2,0.3,Watch\n"
            + "1787009401,1,0.2,-0.3,0.4,Watch\n").utf8)
        let record = try SensorKitAccelerometerRecord(
            sourceRecordID: FHIRSensorKitFixture.sourceID,
            nativeRecording: SensorKitNativeRecording(
                title: "Synthetic acceleration", format: .triaxialAccelerationSamples, payload: .inline(csv), admission: .verifiedSanitizedInput
            )
        )
        return try await FHIRSensorKitFixture.bytes(.accelerometer(record))
    }
}
