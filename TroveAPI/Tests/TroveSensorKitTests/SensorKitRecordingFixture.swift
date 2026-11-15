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
import Testing
import TroveAPIClient
@testable import TroveSensorKit


struct SensorKitRecordingFixture {
    var contract: SensorKitStructuredContract = .accelerometer
    let journal = SensorKitJournalFixture()
    let recordingConsentID = UUID()
    let recordingEnrollmentID = UUID()

    var entry: SensorKitCatalogEntry {
        get throws { try #require(SensorKitCatalog.current.entries.first { $0.structuredContract == contract }) }
    }

    func snapshot(includeRecording: Bool = true) throws -> ParticipantCollectionSnapshot {
        let profiles = try SensorKitAcquisition.requiredProfiles(for: entry)
        let start = journal.instant.addingTimeInterval(-3600)
        let plans = try profiles.enumerated().compactMap { index, profile -> Components.Schemas.ParticipantCollectionPlan? in
            if index == 1 && !includeRecording {
                return nil
            }
            let consentID = index == 0 ? journal.consentID : recordingConsentID
            return .init(
                enrollmentId: (index == 0 ? journal.enrollmentID : recordingEnrollmentID).uuidString.lowercased(),
                studyId: UUID().uuidString.lowercased(),
                title: .init([.enUS: "Sensor study"]),
                stateVersion: 1,
                asOf: journal.instant,
                windows: [
                    .init(
                        consentId: consentID.uuidString.lowercased(),
                        publicationId: UUID().uuidString.lowercased(),
                        revision: 1,
                        start: start,
                        requirements: [
                            .init(profile: profile.rawValue, sourceTypeIdentifier: try entry.sourceToken, sourceKind: .participantApp, start: start)
                        ]
                    )
                ]
            )
        }
        return try ParticipantCollectionSnapshot(
            plans: plans, enrollmentIDs: includeRecording ? [journal.enrollmentID, recordingEnrollmentID] : [journal.enrollmentID]
        )
    }

    func evidence(_ batch: SensorKitAcquisition.Batch, endOffset: TimeInterval = 0) throws -> SensorKitBatchEvidence {
        try SensorKitBatchEvidence(
            sourceTypeIdentifier: batch.sourceToken,
            deviceProductType: batch.deviceProductType,
            coordinate: batch.coordinate,
            effectiveStart: journal.instant,
            effectiveEnd: journal.instant.addingTimeInterval(endOffset),
            replayToken: #require(batch.replayToken),
            firstReceipt: SensorKitBatchReceipt(batch: batch).encoded()
        )
    }

    func batch(acknowledge: @escaping @Sendable () async throws -> Void = {}) throws -> SensorKitAcquisition.Batch {
        var writer = try RecordingCSVFileWriter(format: .triaxialAccelerationSamples, maximumByteCount: 1024 * 1024)
        let timestamp = floor(journal.instant.timeIntervalSince1970)
        for index in 0..<128 {
            try writer.append([.number(timestamp + Double(index) / 100), .integer(1), .number(0.1), .number(0.2), .number(0.3), .text("Watch1,1")])
        }
        let file = try writer.finish()
        let path = "recordings/acceleration.csv"
        let native = try SensorKitNativeRecording(
            title: "Acceleration",
            format: .triaxialAccelerationSamples,
            payload: .file(path: path, contents: file),
            admission: .verifiedSanitizedInput
        )
        let sourceID = SensorKitSourceRecordID(journal.recordID)
        let record = try SensorKitAccelerometerRecord(sourceRecordID: sourceID, nativeRecording: native)
        let profiles = try SensorKitAcquisition.requiredProfiles(for: entry)
        var digest = SHA256()
        try file.readChunks { digest.update(data: $0) }
        return try .init(
            coordinate: "acceleration-batch-one",
            sourceToken: entry.sourceToken,
            deviceProductType: "Watch1,1",
            inputs: [
                .init(
                    sourceID: sourceID,
                    sourceToken: entry.sourceToken,
                    profile: #require(profiles.first),
                    record: .accelerometer(record),
                    digest: Data(digest.finalize()),
                    start: record.coverage.start,
                    end: record.coverage.end,
                    companionProfiles: Array(profiles.dropFirst()),
                    recordings: [.init(file: file, format: .triaxialAccelerationSamples, relativePath: path)]
                )
            ],
            facts: journal.batch().facts,
            acknowledge: acknowledge,
            replayToken: Data([1]),
            nativeSampleCount: 128
        )
    }
}
