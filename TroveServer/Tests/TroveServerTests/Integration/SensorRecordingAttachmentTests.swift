//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveSensorKitFHIR
import SQLKit
import Testing
import TroveAPIClient
@testable import TroveServer
import VaporTesting


struct SensorRecordingAttachmentTests {
    @Test(arguments: [false, true])
    func hybridAdmissionPreservesSeparateStudyGrantsAndExactDownload(compressed: Bool) async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant"), validator: ClinicalEventBatchTests.validator()) { app, token in
            let definition = try SensorRecordingAttachmentFixture.source
            let window = CollectionMeasurementWindow(
                calendar: .gregorian, timeZone: "UTC", start: .absolute(.init(_type: .absolute, date: Date().addingTimeInterval(-3600)))
            )
            let summary = try #require(definition.observation?.primaryProfile)
            let requirements = [summary, SensorKitContract.recordingDocumentProfile].map { profile in
                [
                    CollectionRequirement(
                        profile: profile, sourceKind: .participantApp, measurementWindow: window, sourceTypeIdentifier: definition.sourceToken
                    )
                ]
            }
            let source = try await ClinicalEventStoreTests.prepare(on: app, requirements: requirements, repositoryKind: .sensorKit)
            let payload = try await SensorRecordingAttachmentFixture.make(
                source: source.source, consentID: source.consentIDs[1], compressed: compressed
            )
            let receipt = try await ClinicalRecordingAttachmentTests.upload(payload.recording, source: source, on: app, token: token)
            var submission = payload.recording
            submission.declaration.targets.append(.init(consentId: source.consentIDs[0].uuidString, outputFullUrls: [payload.summaryURL]))
            let result = try await ClinicalRecordingAttachmentTests.submit(
                submission.submission(sourceID: source.source.id, receipt: receipt), source: source, on: app, token: token
            )
            guard case .EventReceipt = try #require(result.first) else { throw ServerError.unexpectedError }
            try await verifyDownload(payload, source: source, on: app)
        }
    }

    private func verifyDownload(
        _ payload: SensorRecordingAttachmentFixture, source: ClinicalEventStoreTests.Fixture, on app: Application
    ) async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        let rows = try await sql.raw("SELECT id, study_id FROM study_data_grants").all()
        try #require(rows.count == 2)
        let originalGrant = try #require(rows.first { try $0.decode(column: "study_id", as: UUID.self) == source.studyIDs[1] })
        let grantID = try originalGrant.decode(column: "id", as: UUID.self)
        let reader = try await StudyRecordingFixture.readerToken()
        let client = try RecordingTransferHTTPTests.client(app, token: reader)
        let response = try await client.getStudyRecording(.init(path: .init(
            studyId: source.studyIDs[1].uuidString, grantId: grantID.uuidString
        ))).ok
        #expect(response.headers.xRecordingContentType == .textCsv)
        #expect(try await Data(collecting: response.body.binary, upTo: 4096) == payload.original)
        let forbidden = StudyRecordingLocation.path(studyID: source.studyIDs[0], grantID: grantID, versions: .current)
        try await app.test(.GET, forbidden, beforeRequest: { $0.bearerAuth(reader) }) { #expect($0.status == .notFound) }
        #expect(try await StudyRecordingFixture.disclosureCount(on: app) == 1)
    }
}
