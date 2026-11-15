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

    /// The first row's whole-second source time; rows follow at 100 Hz.
    var rowInstant: Date { Date(timeIntervalSince1970: floor(journal.instant.timeIntervalSince1970)) }

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

    /// Two studies request the complete producer graph for separate measurement windows.
    func snapshot(studyWindows: [(start: TimeInterval, end: TimeInterval?)]) throws -> ParticipantCollectionSnapshot {
        let profiles = try SensorKitAcquisition.requiredProfiles(for: entry)
        let studies = [(journal.consentID, journal.enrollmentID), (recordingConsentID, recordingEnrollmentID)]
        let plans = try zip(studies, studyWindows).map { study, window -> Components.Schemas.ParticipantCollectionPlan in
            let start = rowInstant.addingTimeInterval(window.start)
            let end = window.end.map(rowInstant.addingTimeInterval)
            return .init(
                enrollmentId: study.1.uuidString.lowercased(),
                studyId: UUID().uuidString.lowercased(),
                title: .init([.enUS: "Sensor study"]),
                stateVersion: 1,
                asOf: journal.instant,
                windows: [
                    .init(
                        consentId: study.0.uuidString.lowercased(),
                        publicationId: UUID().uuidString.lowercased(),
                        revision: 1,
                        start: journal.instant.addingTimeInterval(-3600),
                        requirements: try profiles.map {
                            .init(
                                profile: $0.rawValue, sourceTypeIdentifier: try entry.sourceToken, sourceKind: .participantApp, start: start, end: end
                            )
                        }
                    )
                ]
            )
        }
        return try ParticipantCollectionSnapshot(plans: plans, enrollmentIDs: studies.prefix(plans.count).map(\.1))
    }

    /// Mirrors the adapter's slice planning with caller-assigned identities; derived identities need the iOS bridge.
    func slicePreparation(
        snapshot: ParticipantCollectionSnapshot, state: ParticipantCollectionState
    ) throws -> SensorKitAcquisition.SlicePreparation {
        let profiles = try SensorKitAcquisition.requiredProfiles(for: entry)
        let token = try entry.sourceToken
        let authority: (Int) throws -> SensorKitSliceSelection.Authority? = { row in
            try SensorKitSliceSelection.authority(for: rowInterval(row), profiles: profiles, sourceTypeIdentifier: token, snapshot: snapshot)
        }
        var inputs: [SensorKitAcquisition.Input] = []
        var slices: [SensorKitRecordingSlice] = []
        for range in try SensorKitSliceSelection.ranges(count: 128, retained: [], maximumSlices: 16, authority: authority) {
            var input = try input(rows: range, sourceRecordID: UUID())
            let shared = try SensorKitSliceSelection.sharedAuthority(range, authority: authority)
            input.rowAuthorization = .init(consents: try #require(shared))
            slices.append(try .init(rows: range, sourceRecordID: input.sourceID.uuid, contentDigest: input.digest))
            inputs.append(input)
        }
        return .init(inputs: inputs, state: state, slices: slices)
    }

    /// One native sample whose last accelerometer value lies one second after its start.
    func photoplethysmogram() -> SensorKitPPGRecording {
        SensorKitPPGRecording(records: [
            .init(
                startDate: rowInstant,
                nanosecondsSinceStart: 0,
                temperature: nil,
                usage: [],
                opticalSamples: [],
                accelerometerSamples: [.init(nanosecondsSinceStart: 1_000_000_000, samplingFrequency: 100, x: 0.1, y: 0.2, z: 0.3)]
            )
        ])
    }

    func rowInterval(_ row: Int) -> Range<Date> {
        let instant = rowInstant.addingTimeInterval(Double(row) / 100)
        return instant..<instant
    }

    func batch(acknowledge: @escaping @Sendable () async throws -> Void = {}) throws -> SensorKitAcquisition.Batch {
        try .init(
            coordinate: "acceleration-batch-one",
            sourceToken: entry.sourceToken,
            deviceProductType: "Watch1,1",
            inputs: [input(rows: 0..<128, sourceRecordID: journal.recordID)],
            facts: journal.batch().facts,
            acknowledge: acknowledge,
            replayToken: Data([1]),
            nativeSampleCount: 128
        )
    }

    func input(rows: Range<Int>, sourceRecordID: UUID) throws -> SensorKitAcquisition.Input {
        var writer = try RecordingCSVFileWriter(format: .triaxialAccelerationSamples, maximumByteCount: 1024 * 1024)
        let timestamp = rowInstant.timeIntervalSince1970
        for index in rows {
            try writer.append([.number(timestamp + Double(index) / 100), .integer(1), .number(0.1), .number(0.2), .number(0.3), .text("Watch1,1")])
        }
        let file = try writer.finish()
        let path = "recordings/\(sourceRecordID.uuidString.lowercased()).csv"
        let native = try SensorKitNativeRecording(
            title: "Acceleration",
            format: .triaxialAccelerationSamples,
            payload: .file(path: path, contents: file),
            admission: .verifiedSanitizedInput
        )
        let sourceID = SensorKitSourceRecordID(sourceRecordID)
        let record = try SensorKitAccelerometerRecord(sourceRecordID: sourceID, nativeRecording: native)
        let profiles = try SensorKitAcquisition.requiredProfiles(for: entry)
        var digest = SHA256()
        try file.readChunks { digest.update(data: $0) }
        return try .init(
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
    }
}
