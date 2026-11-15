//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import SQLKit
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


struct StudyRecordingDataTests {
    @Test(arguments: [false, true])
    func retainedRecordingPagesUseAdmissionEvidenceAndCurrentStudyAuthority(compressed: Bool) async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant"), validator: ClinicalEventBatchTests.validator()) { app, token in
            let source = try await RecordingTransferHTTPTests.prepare(on: app)
            let fixture = try RecordingAttachmentFixture.make(source: source.source, consentID: source.consentIDs[0], compressed: compressed)
            let receipt = try await ClinicalRecordingAttachmentTests.upload(fixture, source: source, on: app, token: token)
            let result = try await ClinicalRecordingAttachmentTests.submit(
                fixture.submission(sourceID: source.source.id, receipt: receipt), source: source, on: app, token: token
            )
            guard case .EventReceipt = try #require(result.first) else {
                Issue.record("Recording was not admitted")
                return
            }
            let artifact = try #require(try await StoredArtifact.find(UUID(uuidString: receipt.artifactId), on: app.db))
            artifact.expiresAt = Date(timeIntervalSince1970: 0)
            try await artifact.save(on: app.db)
            // Listing uses the immutable admission evidence; no object fetch is needed for the FHIR view.
            try await app.grove[ObjectStorageService.self].delete(key: artifact.reference().key)
            let page = try await Self.page(source.studyIDs[0], app: app)
            let record = try #require(page.records.first)
            #expect(page.records.count == 1 && record.outputs.count == 1)
            #expect(record.outputs[0].sourceProfiles.contains(FHIRRecordingProjection.profile))
            let resources = try StudyDataFixture.resources(record)
            let document = try #require(resources.first { $0["resourceType"] as? String == "DocumentReference" })
            let contents = try #require(document["content"] as? [[String: Any]])
            let attachment = try #require(contents.first?["attachment"] as? [String: Any])
            let location = try #require(attachment["url"] as? String)
            #expect(location.hasPrefix("/\(apiBasePath)/studies/\(source.studyIDs[0].uuidString.lowercased())/data/recordings/"))
            #expect(location.hasSuffix("?versions=current"))
            #expect(attachment["size"] as? Int64 == fixture.declaration.content.sourceByteCount)
            #expect(attachment["data"] == nil)
            #expect(try await Self.page(source.studyIDs[1], app: app).records.isEmpty)
            #expect(try await StudyDataFixture.disclosureCount(on: app.db) == 2)
            try await Self.expectImmutableEvidence(fixture.record, app: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: source.enrollmentIDs[0])
            }
            #expect(try await Self.page(source.studyIDs[0], app: app).records.isEmpty)
        }
    }

    @Test
    func recordingDisclosureRequiresAnAuditCommit() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant"), validator: ClinicalEventBatchTests.validator()) { app, token in
            let source = try await RecordingTransferHTTPTests.prepare(on: app)
            let fixture = try RecordingAttachmentFixture.make(source: source.source, consentID: source.consentIDs[0], compressed: true)
            let receipt = try await ClinicalRecordingAttachmentTests.upload(fixture, source: source, on: app, token: token)
            let result = try await ClinicalRecordingAttachmentTests.submit(
                fixture.submission(sourceID: source.source.id, receipt: receipt), source: source, on: app, token: token
            )
            guard case .EventReceipt = try #require(result.first) else {
                Issue.record("Recording was not admitted")
                return
            }
            #expect(try await Self.page(source.studyIDs[0], app: app).records.count == 1)
            #expect(try await StudyDataFixture.disclosureCount(on: app.db) == 1)
            try await StudyDataFixture.rejectAudit(on: app.db)
            await #expect(throws: (any Error).self) { try await Self.page(source.studyIDs[0], app: app) }
            #expect(try await StudyDataFixture.disclosureCount(on: app.db) == 1)
            try await ClinicalRecordingAttachmentTests.expectAttachment(receipt, count: 1, state: .retained, on: app)
        }
    }
}


extension StudyRecordingDataTests {
    private static func expectImmutableEvidence(_ expected: Data, app: Application) async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        await #expect(throws: (any Error).self) {
            try await sql.raw("UPDATE clinical_recording_attachments SET content_evidence = '{}'").run()
        }
        let retained = try #require(try await sql.raw("SELECT raw_bytes FROM clinical_events").first())
        #expect(try retained.decode(column: "raw_bytes", as: Data.self) == expected)
    }

    private static func page(_ studyID: UUID, app: Application) async throws -> Components.Schemas.StudyDataPage {
        let reader = AuthContext(
            issuer: TestApp.issuer,
            subject: "researcher-test-user",
            email: "test@example.com",
            roles: [TestApp.researcherRole],
            groups: ["/Test Group/researcher", "/Test Group/data-reader"],
            researcherRole: TestApp.researcherRole,
            participantRole: TestApp.participantRole
        )
        return try await AuthContext.$current.withValue(reader) {
            try await app.grove[StudyService.self].dataPage(studyID: studyID, versions: .current, before: nil, limit: 1)
        }
    }
}
