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


struct FHIRSensorKitRecordingTests {
    @Test("Raw sensor recordings retain their source-specific format and exact source interval", arguments: [
        RegisteredRecordingFormat.heartRateSamples, .pedometerSamples, .ambientLightSamples
    ])
    func rawGraphRoundTrips(_ format: RegisteredRecordingFormat) async throws {
        let source = try Self.source(format)
        let payload = try Self.payload(format)
        let record = try SensorKitRawRecord(
            sourceRecordID: FHIRSensorKitFixture.sourceID,
            sourceToken: source.sourceToken,
            effectivePeriod: DateInterval(start: FHIRSensorKitFixture.start, end: FHIRSensorKitFixture.end),
            nativeRecording: SensorKitNativeRecording(
                title: "Synthetic sensor recording", format: format, payload: .inline(payload), admission: .verifiedSanitizedInput
            )
        )
        let bytes = try await FHIRSensorKitFixture.bytes(.raw(record))
        let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "synthetic-receiver-test")
        let output = try #require(event.outputs.first)
        #expect(event.outputs.count == 1 && output.value == .recording)
        #expect(output.sourceRepositoryKind == .sensorKit)
        #expect(output.sourceTypeIdentifier == source.sourceToken)
        #expect(output.code == format.rawValue)
        #expect(output.measurementBounds == (try .init(start: FHIRSensorKitFixture.start, end: FHIRSensorKitFixture.end)))
        let projected = try StudyPointProjection.project(
            event, outputs: [output.fullURL], subject: .init(system: IdentifierSystem("https://example.test/study-subject"), value: "synthetic")
        )
        let bundle = try JSONDecoder().decode(ModelsR4.Bundle.self, from: projected.json)
        let document = try #require(bundle.entry?.compactMap { $0.resource?.get() as? DocumentReference }.first)
        #expect(document.content.first?.attachment.data?.value?.data() == payload)
    }

    @Test("A format cannot be relabeled as a different native stream")
    func sourceFormatMismatchFails() async throws {
        let source = try Self.source(.heartRateSamples)
        let record = try SensorKitRawRecord(
            sourceRecordID: FHIRSensorKitFixture.sourceID,
            sourceToken: source.sourceToken,
            effectivePeriod: DateInterval(start: FHIRSensorKitFixture.start, end: FHIRSensorKitFixture.end),
            nativeRecording: SensorKitNativeRecording(
                title: "Synthetic recording",
                format: .heartRateSamples,
                payload: .inline(Self.payload(.heartRateSamples)),
                admission: .verifiedSanitizedInput
            )
        )
        let bytes = try await FHIRSensorKitFixture.bytes(.raw(record))
        let bundle = try JSONDecoder().decode(ModelsR4.Bundle.self, from: bytes)
        var document = try #require(bundle.entry?.compactMap { $0.resource?.get() as? DocumentReference }.first)
        let other = try Self.source(.pedometerSamples)
        document.extension = [Extension(url: Canonicals.sensorKitSourceTypeExtension, value: .code(FHIRPrimitive(FHIRString(other.sourceTypeCode))))]
        #expect(throws: (any Error).self) { try FHIRRecordingProjection.project(document) }
    }
}


extension FHIRSensorKitRecordingTests {
    static func source(_ format: RegisteredRecordingFormat) throws -> SensorKitCatalogEntry {
        try #require(SensorKitCatalog.current.entries.first {
            $0.structuredContract == nil && $0.rawFormats.contains(format) && $0.implementedOutput != nil
        })
    }

    static func payload(_ format: RegisteredRecordingFormat) throws -> Data {
        switch format {
        case .heartRateSamples: Data("timestamp,value,confidence,device\n1787009400,72,3,Watch\n".utf8)
        case .pedometerSamples:
            Data(("start,end,steps,distance,floorsUp,floorsDown,currentPace,currentCadence,avgActivePace,device\n"
                + "1787009400,1787009460,5,,,,,,,Watch\n").utf8)
        case .ambientLightSamples:
            Data("timestamp,lux,placement,chromaticityX,chromaticityY,device\n1787009400,42,front,0.3,0.4,Watch\n".utf8)
        case .nativeRecording: Data("{\"synthetic\":true}".utf8)
        default: throw CocoaError(.featureUnsupported)
        }
    }
}
