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
import TroveAPITypes
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

    @Test("A photoplethysmogram sample keeps its binary recording beside a separately selectable coverage summary")
    func photoplethysmogramHybridProjectsBothOutputs() async throws {
        let recording = SensorKitPPGRecording(records: [
            .init(
                startDate: FHIRSensorKitFixture.start,
                nanosecondsSinceStart: 0,
                temperature: 31.5,
                usage: ["deep-breathing"],
                opticalSamples: [
                    .init(
                        emitter: 1,
                        activePhotodiodeIndexes: [0, 2],
                        signalIdentifier: 7,
                        nominalWavelength: 525,
                        effectiveWavelength: 526.5,
                        samplingFrequency: 256,
                        nanosecondsSinceStart: 1_000_000_000,
                        conditions: ["signal-saturation"],
                        noiseTerms: nil,
                        normalizedReflectance: 0.42
                    )
                ],
                accelerometerSamples: [.init(nanosecondsSinceStart: 500_000_000, samplingFrequency: 100, x: 0.1, y: -0.2, z: 0.9)]
            )
        ])
        let record = try recording.prepared().sensorKitRecord(
            sourceRecordID: FHIRSensorKitFixture.sourceID, title: "Synthetic recording", location: .inline, admission: .verifiedSanitizedInput
        )
        let event = try FHIRPointProjection.project(
            validatedBytes: await FHIRSensorKitFixture.bytes(record), validatorIdentity: "synthetic-receiver-test"
        )
        let definition = try #require(SensorKitCatalog.current.entries.first { $0.structuredContract == .ppg }?.implementedOutput)
        let summary = try #require(event.outputs.first { $0.value != .recording })
        let original = try #require(event.outputs.first { $0.value == .recording })
        #expect(event.outputs.count == 2 && summary.value == .components)
        #expect(summary.profile == definition.observation?.primaryProfile && summary.sourceTypeIdentifier == definition.sourceToken)
        #expect(original.code == RegisteredRecordingFormat.photoplethysmogramSamples.rawValue)
        #expect(original.measurementBounds == summary.measurementBounds)
        let start = FHIRSensorKitFixture.start
        #expect(summary.measurementBounds == (try .init(start: start, end: start.addingTimeInterval(1))))
        // A native sample is one record: it keeps whole-overlap selection instead of row coverage.
        #expect(event.collectionOutputs.allSatisfy { $0.rowExtent == nil && !$0.lacksRowEvidence })
        let outputs = SensorKitCollectionCapabilities.outputs(for: definition.sourceToken)
        #expect(outputs.map(\.isRecording) == [false, true])
        #expect(outputs.first?.requiredCompanionProfiles == [SensorKitContract.recordingDocumentProfile])
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
