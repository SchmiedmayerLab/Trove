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
@testable import TroveServer
import VaporTesting


private actor ConsentEvidenceStorage: ObjectStorageProvider {
    private var objects: [String: Data] = [:]
    private let corruptUploads: Bool
    private(set) var downloads: [String] = []

    init(corruptUploads: Bool = false) {
        self.corruptUploads = corruptUploads
    }

    func upload(data: Data, key: String, contentType: String) {
        objects[key] = corruptUploads ? data + Data("CORRUPTED".utf8) : data
    }

    func download(key: String, maximumBytes: Int = 50 * 1024 * 1024) throws -> Data {
        downloads.append(key)
        guard let data = objects[key] else {
            throw ServerError.notFound("Synthetic evidence not found")
        }
        return data
    }

    func ensureBucketExists() {}
    func delete(key: String) { objects.removeValue(forKey: key) }
    func shutdown() {}
}


struct ConsentEvidenceIntegrityTests {
    private static let subject = "consent-evidence-participant"
    private static let privatePDF = Data("%PDF-1.4 PRIVATE-CONSENT-EVIDENCE".utf8)

    @Test
    func corruptedStagedEvidenceCannotBeAccepted() async throws {
        let storage = ConsentEvidenceStorage(corruptUploads: true)
        try await TestApp.withApp(token: .participant(subject: Self.subject), storageProvider: storage) { app, token in
            let beforeRequest = try await Self.pendingEnrollment(on: app)
            let enrollmentID = try beforeRequest.requireId()
            let presentation = try await ConsentRequestFixtures.presentation(on: app, enrollmentID: enrollmentID.uuidString, token: token)
            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(enrollmentID)/consents", beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeMultipartConsentBody(
                    commandID: UUID(),
                    enrollmentETag: presentation.enrollmentETag,
                    consentData: ["toggles": ["agree": true], "selects": [:], "signatures": [:]],
                    presentation: presentation.presentation,
                    pdfData: Self.privatePDF,
                    reviewedRevision: presentation.revision
                )
            }) { response in
                #expect(response.status == .conflict)
                Self.expectNoEvidence(in: response)
            }
            let consentCount = try await EnrollmentConsent.query(on: app.db).count()
            #expect(consentCount == 0)
            try await Self.expectNoConsentAudit(on: app)
            let retained = try #require(try await Enrollment.find(enrollmentID, on: app.db))
            #expect(retained.currentRevision == beforeRequest.currentRevision)
            #expect(retained.stateVersion == beforeRequest.stateVersion)
            #expect(retained.withdrawnAt == nil)
            #expect(retained.updatedAt == beforeRequest.updatedAt)
            #expect(await storage.downloads.count == 1)
        }
    }

    @Test
    func corruptPDFIsNotDisclosed() async throws {
        let storage = ConsentEvidenceStorage()
        try await TestApp.withApp(token: .participant(subject: Self.subject), storageProvider: storage) { app, token in
            let record = try await Self.fixture(on: app, bytes: Data("accepted PDF".utf8))
            await storage.upload(data: Self.privatePDF, key: record.evidenceKey, contentType: "application/pdf")
            try await Self.download(record, app: app, token: token) { response in
                #expect(response.status == .internalServerError)
                Self.expectNoEvidence(in: response)
            }
            #expect(await storage.downloads == [record.evidenceKey])
        }
    }

    @Test(arguments: [
        "evidence_key", "evidence_digest", "artifact_id", "presentation_proof",
        "command_id", "expected_enrollment_version", "accepted_enrollment_version"
    ])
    func consentRequiresCompleteRetainedEvidence(column: String) async throws {
        try await TestApp.withApp { app, _ in
            let record = try await Self.fixture(on: app, bytes: Self.privatePDF)
            let candidate = try await RetainedRecordFixtures.consent(on: app.db, enrollmentID: record.$enrollment.id, revision: 2)
            candidate.expectedEnrollmentVersion = 2
            candidate.acceptedEnrollmentVersion = 3
            switch column {
            case "evidence_key": candidate.$evidenceKey.value = nil
            case "evidence_digest": candidate.$evidenceDigest.value = nil
            case "artifact_id": candidate.$artifactID.value = nil
            case "presentation_proof": candidate.$presentationProof.value = nil
            case "command_id": candidate.$commandID.value = nil
            case "expected_enrollment_version": candidate.$expectedEnrollmentVersion.value = nil
            default: candidate.$acceptedEnrollmentVersion.value = nil
            }
            await #expect {
                try await candidate.save(on: app.db)
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            let retained = try #require(try await EnrollmentConsent.find(record.requireId(), on: app.db))
            #expect(retained.evidenceKey == record.evidenceKey)
            #expect(retained.evidenceDigest == record.evidenceDigest)
            #expect(retained.artifactID == record.artifactID)
            #expect(retained.presentationProof == record.presentationProof)
            #expect(retained.commandID == record.commandID)
            #expect(retained.expectedEnrollmentVersion == record.expectedEnrollmentVersion)
            #expect(retained.acceptedEnrollmentVersion == record.acceptedEnrollmentVersion)
        }
    }

    @Test
    func retainedPDFIsVerifiedBeforeDisclosure() async throws {
        let storage = ConsentEvidenceStorage()
        try await TestApp.withApp(token: .participant(subject: Self.subject), storageProvider: storage) { app, token in
            let record = try await Self.fixture(on: app, bytes: Self.privatePDF)
            await storage.upload(data: Self.privatePDF, key: record.evidenceKey, contentType: "application/pdf")
            try await Self.download(record, app: app, token: token) { response in
                #expect(response.status == .ok)
                #expect(Data(buffer: response.body) == Self.privatePDF)
            }
            #expect(await storage.downloads == [record.evidenceKey])
        }
    }

    @Test
    func auditFailurePreventsPDFDownloadAndDisclosure() async throws {
        let storage = ConsentEvidenceStorage()
        try await TestApp.withApp(token: .participant(subject: Self.subject), storageProvider: storage) { app, token in
            let record = try await Self.fixture(on: app, bytes: Self.privatePDF)
            await storage.upload(data: Self.privatePDF, key: record.evidenceKey, contentType: "application/pdf")
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("DROP TABLE audit_events").run()
            try await Self.download(record, app: app, token: token) { response in
                #expect(response.status == .internalServerError)
                Self.expectNoEvidence(in: response)
            }
            #expect(await storage.downloads.isEmpty)
        }
    }
}


extension ConsentEvidenceIntegrityTests {
    private static func expectNoConsentAudit(on app: Application) async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM audit_events WHERE action = 'consent.recorded'").first())
        #expect(try row.decode(column: "count", as: Int.self) == 0)
    }

    private static func pendingEnrollment(on app: Application) async throws -> Enrollment {
        let group = try await GroupFixtures.createGroup(on: app.db)
        let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
        let participant = try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: subject)
        try await PublishedStudyFixtures.createPublishedStudy(
            on: app.db,
            studyId: study.requireId(),
            revision: 1,
            consentSnapshot: .init([.enUS: PublishedStudyFixtures.requiredConsentMarkdown])
        )
        let enrollment = Enrollment(participantId: try participant.requireId(), studyId: try study.requireId(), currentRevision: 1)
        try await enrollment.save(on: app.db)
        let id = try enrollment.requireId()
        // The baseline must contain the database's timestamp representation, not an unsaved Date.
        return try #require(try await Enrollment.find(id, on: app.db))
    }

    private static func fixture(on app: Application, bytes: Data) async throws -> EnrollmentConsent {
        let group = try await GroupFixtures.createGroup(on: app.db)
        let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
        let participant = try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: subject)
        let enrollment = Enrollment(participantId: try participant.requireId(), studyId: try study.requireId(), currentRevision: 1)
        try await enrollment.save(on: app.db)
        let record = try await RetainedRecordFixtures.consent(on: app.db, enrollmentID: enrollment.requireId(), bytes: bytes)
        try await record.save(on: app.db)
        return record
    }

    private static func download(
        _ record: EnrollmentConsent,
        app: Application,
        token: String?,
        verify: @escaping @Sendable (TestingHTTPResponse) async throws -> Void
    ) async throws {
        let path = "\(apiBasePath)/participant/enrollments/\(record.$enrollment.id)/consents/\(try record.requireId())/pdf"
        try await app.test(.GET, path, beforeRequest: { $0.bearerAuth(token) }, afterResponse: verify)
    }

    private static func expectNoEvidence(in response: TestingHTTPResponse) {
        #expect(!response.body.string.contains("PRIVATE-CONSENT-EVIDENCE"))
        #expect(!response.body.string.contains("%PDF"))
        #expect(response.headers.contentType != .pdf)
    }
}
