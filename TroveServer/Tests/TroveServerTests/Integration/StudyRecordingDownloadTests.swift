//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Fluent
import Foundation
import Testing
import TroveAPIClient
@testable import TroveServer
import VaporTesting


struct StudyRecordingDownloadTests {
    @Test(arguments: [false, true])
    func generatedClientAndExportedLinkReturnExactBytesAfterTransferExpiry(compressed: Bool) async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant"), validator: ClinicalEventBatchTests.validator()) { app, token in
            let fixture = try await StudyRecordingFixture.prepare(on: app, token: token, compressed: compressed)
            try await StoredArtifact.query(on: app.db)
                .filter(\.$id == fixture.artifactID)
                .set(\.$expiresAt, to: Date(timeIntervalSince1970: 0))
                .update()
            let readerToken = try await StudyRecordingFixture.readerToken()
            let client = try RecordingTransferHTTPTests.client(app, token: readerToken)
            let study = fixture.source.studyIDs[0]
            let page = try await client.getStudyData(.init(path: .init(studyId: study.uuidString))).ok.body.json
            let resources = try StudyDataFixture.resources(#require(page.records.first))
            let document = try #require(resources.first { $0["resourceType"] as? String == "DocumentReference" })
            let content = try #require(document["content"] as? [[String: Any]])
            let attachment = try #require(content[0]["attachment"] as? [String: Any])
            let location = try #require(attachment["url"] as? String)
            #expect(location == StudyRecordingLocation.path(studyID: study, grantID: fixture.grantID, versions: .current))
            let response = try await client.getStudyRecording(.init(path: .init(studyId: study.uuidString, grantId: fixture.grantID.uuidString))).ok
            #expect(response.headers.cacheControl == .noStore)
            let bytes = try await Data(collecting: response.body.csv, upTo: 1024 * 1024)
            #expect(Int64(bytes.count) == fixture.recording.declaration.content.sourceByteCount)
            #expect(ArtifactStore.digest(bytes) == fixture.recording.declaration.content.sourceSHA256)
            #expect(Data(Insecure.SHA1.hash(data: bytes)).base64EncodedString() == attachment["hash"] as? String)
            try await app.test(.GET, location, beforeRequest: { $0.bearerAuth(readerToken) }) { result in
                #expect(result.status == .ok && result.body.readableBytesView.elementsEqual(bytes))
                #expect(result.headers.first(name: .cacheControl) == "no-store")
            }
            #expect(try await StudyRecordingFixture.disclosureCount(on: app) == 2)
        }
    }

    @Test(arguments: ["participant", "no-capability", "foreign-study", "unknown-grant", "withdrawn", "retracted"])
    func deniedDownloadsNeverReadStorage(reason: String) async throws {
        let storage = RecordingDownloadStorage()
        try await TestApp.withApp(
            token: .participant(subject: "test-participant"), storageProvider: storage, validator: ClinicalEventBatchTests.validator()
        ) { app, token in
            let fixture = try await StudyRecordingFixture.prepare(on: app, token: token)
            if reason == "withdrawn" { try await fixture.withdraw(on: app) }
            if reason == "retracted" { try await fixture.retract(on: app) }
            let groups = reason == "no-capability" ? ["/Test Group/admin"] : ["/Test Group/researcher", "/Test Group/data-reader"]
            let readerToken = try await reason == "participant" ? token : StudyRecordingFixture.readerToken(groups: groups)
            let study = fixture.source.studyIDs[reason == "foreign-study" ? 1 : 0]
            let grant = reason == "unknown-grant" ? UUID() : fixture.grantID
            await storage.reset()
            let location = StudyRecordingLocation.path(studyID: study, grantID: grant, versions: .history)
            try await app.test(.GET, location, beforeRequest: { $0.bearerAuth(readerToken) }) {
                #expect($0.status.code == (["participant", "no-capability"].contains(reason) ? 403 : 404))
            }
            #expect(await storage.reads == 0)
            #expect(try await StudyRecordingFixture.disclosureCount(on: app) == 0)
        }
    }

    @Test(arguments: ["withdrawn", "retracted", "expired-token", "audit", "corrupt", "truncated", "missing"])
    func racesAndIntegrityFailuresReleaseNoRecording(reason: String) async throws {
        let storage = RecordingDownloadStorage()
        try await TestApp.withApp(
            token: .participant(subject: "test-participant"), storageProvider: storage, validator: ClinicalEventBatchTests.validator()
        ) { app, token in
            let fixture = try await StudyRecordingFixture.prepare(on: app, token: token)
            try await Self.prepareFailure(reason, fixture: fixture, storage: storage, app: app)
            let readerToken = try await StudyRecordingFixture.readerToken(
                expiration: Date().addingTimeInterval(reason == "expired-token" ? 2 : 3600)
            )
            let location = StudyRecordingLocation.path(studyID: fixture.source.studyIDs[0], grantID: fixture.grantID, versions: .current)
            try await app.test(.GET, location, beforeRequest: { $0.bearerAuth(readerToken) }) {
                let expected = Self.expectedFailure(reason)
                #expect($0.status.code == expected)
                #expect(!$0.body.string.contains("timestamp,latitude"))
            }
            #expect(await storage.reads == 1)
            #expect(try await StudyRecordingFixture.disclosureCount(on: app) == 0)
            #expect(try await StoredArtifact.find(fixture.artifactID, on: app.db)?.state == .retained)
        }
    }

    @Test
    func downloadBudgetDoesNotChangeUploadCapacityAndRefusesBeforeStorage() async throws {
        let storage = RecordingDownloadStorage()
        try await TestApp.withApp(
            token: .participant(subject: "test-participant"),
            storageProvider: storage,
            validator: ClinicalEventBatchTests.validator(),
            recordingDownloadByteLimit: "1"
        ) { app, token in
            let fixture = try await StudyRecordingFixture.prepare(on: app, token: token)
            await storage.reset()
            let readerToken = try await StudyRecordingFixture.readerToken()
            let location = StudyRecordingLocation.path(studyID: fixture.source.studyIDs[0], grantID: fixture.grantID, versions: .current)
            try await app.test(.GET, location, beforeRequest: { $0.bearerAuth(readerToken) }) { #expect($0.status == .serviceUnavailable) }
            #expect(await storage.reads == 0)
            #expect(try await StudyRecordingFixture.disclosureCount(on: app) == 0)
        }
    }
}


extension StudyRecordingDownloadTests {
    private static func expectedFailure(_ reason: String) -> Int {
        switch reason {
        case "withdrawn", "retracted": 409
        case "expired-token": 401
        case "audit": 500
        default: 503
        }
    }

    private static func prepareFailure(
        _ reason: String, fixture: StudyRecordingFixture, storage: RecordingDownloadStorage, app: Application
    ) async throws {
        await storage.reset {
            if reason == "withdrawn" { try await fixture.withdraw(on: app) }
            if reason == "retracted" { try await fixture.retract(on: app) }
            if reason == "expired-token" { try await Task.sleep(for: .seconds(3)) }
        }
        if reason == "audit" { try await StudyRecordingFixture.rejectAudit(on: app) }
        let artifact = try #require(try await StoredArtifact.find(fixture.artifactID, on: app.db))
        if reason == "missing" { try await storage.delete(key: artifact.reference().key) }
        if reason == "corrupt" {
            try await storage.upload(data: Data(repeating: 0, count: artifact.byteCount), key: artifact.reference().key, contentType: "text/csv")
        }
        if reason == "truncated" {
            try await storage.upload(data: fixture.recording.stored.dropLast(), key: artifact.reference().key, contentType: "text/csv")
        }
    }
}
