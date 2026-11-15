//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import GroveFHIRContract
import GroveSensorKitFHIR
import ModelsR4
import Testing
import TroveAPIClient
@testable import TroveServer


struct SensorRecordingAttachmentFixture {
    static var source: SensorKitOutputDefinition {
        get throws {
            try #require(SensorKitCatalog.current.entries.first { $0.structuredContract == .accelerometer }?.implementedOutput)
        }
    }

    /// The first row's whole-second source time; later rows follow one second apart.
    static var firstRow: Date { Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 10) }

    var recording: RecordingAttachmentFixture
    let summaryURL: String
    let original: Data

    var recordingURL: String { recording.declaration.outputFullUrl }
    var outputURLs: [String] { [recordingURL, summaryURL] }

    static func make(
        source: SourceBinding, consentID: UUID, compressed: Bool, firstRow start: Date = firstRow, rowCount: Int = 2
    ) async throws -> Self {
        let end = start.addingTimeInterval(Double(rowCount - 1))
        let rows = (0..<rowCount).map { "\(Int(start.timeIntervalSince1970) + $0),1,-0.1,0.2,0.3,Watch\n" }
        let bytes = Data(("timestamp,identifier,x,y,z,device\n" + rows.joined()).utf8)
        let path = "recordings/acceleration.csv"
        let record = try SensorKitAccelerometerRecord(
            sourceRecordID: SensorKitSourceRecordID(UUID()),
            nativeRecording: SensorKitNativeRecording(
                title: "Synthetic acceleration",
                format: .triaxialAccelerationSamples,
                payload: .sidecar(path: path, bytes: bytes),
                admission: .verifiedSanitizedInput
            )
        )
        let json = try await export(record, source: source)
        let graph = try ExchangeGraph(validating: json, kind: .active)
        let document = graph.bundle.entry?.first { $0.resource?.resourceType == "DocumentReference" }
        let originalURL = try #require(document?.fullUrl?.value?.url.absoluteString)
        let summaryURL = try #require(graph.bundle.entry?.first { $0.resource?.resourceType == "Observation" }?.fullUrl?.value?.url.absoluteString)
        let stored = try compressed ? RecordingAttachmentFixture.compress(bytes) : bytes
        let declaration = try Components.Schemas.RecordingTransferDeclaration(
            attachmentPath: path,
            outputFullUrl: originalURL,
            profile: SensorKitContract.recordingDocumentProfile,
            sourceTypeIdentifier: Self.source.sourceToken,
            format: RegisteredRecordingFormat.triaxialAccelerationSamples.rawValue,
            effectiveAt: start,
            effectiveEnd: end,
            content: .init(
                encoding: compressed ? .zstd : .identity,
                storedByteCount: Int64(stored.count),
                storedSHA256: ArtifactStore.digest(stored),
                sourceByteCount: Int64(bytes.count),
                sourceSHA256: ArtifactStore.digest(bytes)
            ),
            targets: [.init(consentId: consentID.uuidString, outputFullUrls: [originalURL])]
        )
        return .init(recording: .init(record: json, stored: stored, declaration: declaration), summaryURL: summaryURL, original: bytes)
    }

    private static func export(_ record: SensorKitAccelerometerRecord, source: SourceBinding) async throws -> Data {
        let producer = try ExchangeProducer(
            identityScope: .init(
                root: IdentifierSystem(source.identifierRoot),
                keyID: source.keyID.uuidString.lowercased(),
                epoch: KeyEpoch(1),
                key: SymmetricKey(data: Data(repeating: 0x35, count: 32))
            ),
            subject: .logical(.init(system: IdentifierSystem(source.participantIdentifierSystem), value: source.participantIdentifierValue)),
            application: .init(name: "Trove", bundleIdentifier: "org.example.Trove", version: "1"),
            host: .init(operatingSystemName: "Linux", operatingSystemVersion: "6")
        )
        let exporter = try SensorKitFHIRExporter(
            producer: producer,
            repositoryScope: .init(system: IdentifierSystem("https://example.test/sensor-repository"), value: "primary"),
            visitLocationIdentifierSystem: IdentifierSystem("https://example.test/sensor-location")
        )
        var records: [Data] = []
        try await exporter.export(
            [.accelerometer(record)], sourceTimeZone: #require(TimeZone(secondsFromGMT: 0)), recordingDevice: nil, at: Date()
        ) { result in
            switch result.outcome {
            case .record(let record): records.append(record.json)
            case .refused(let failure): throw failure
            }
        }
        return try #require(records.first)
    }
}
