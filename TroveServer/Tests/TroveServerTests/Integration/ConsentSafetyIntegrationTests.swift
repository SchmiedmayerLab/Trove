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


struct ConsentSafetyIntegrationTests {
    private static let subject = "consent-safety-participant"

    private static func fixture(on app: Application) async throws -> Enrollment {
        let group = try await GroupFixtures.createGroup(on: app.db)
        let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
        let participant = try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: subject)
        try await PublishedStudyFixtures.createPublishedStudy(
            on: app.db,
            studyId: try study.requireId(),
            revision: 1,
            consentSnapshot: .init([.enUS: PublishedStudyFixtures.requiredConsentMarkdown])
        )
        let enrollment = Enrollment(participantId: try participant.requireId(), studyId: try study.requireId(), currentRevision: 1)
        try await enrollment.save(on: app.db)
        return enrollment
    }

    private static func consentData() -> [String: Any] {
        ["toggles": ["agree": true], "selects": [:], "signatures": [:]]
    }

    @Test
    func newerPublicationDoesNotChangeReviewedRevision() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.subject)) { app, token in
            let enrollment = try await Self.fixture(on: app)
            try await PublishedStudyFixtures.createPublishedStudy(on: app.db, studyId: enrollment.$study.id, revision: 2)
            let id = try enrollment.requireId()
            let presentation = try await ConsentRequestFixtures.presentation(on: app, enrollmentID: id.uuidString, token: token)
            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(id)/consents", beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeMultipartConsentBody(
                    commandID: UUID(),
                    enrollmentETag: presentation.enrollmentETag,
                    consentData: Self.consentData(),
                    presentation: presentation.presentation,
                    reviewedRevision: 1
                )
            }) { response in
                #expect(response.status == .created)
                let receipt = try response.content.decode(Components.Schemas.ConsentRecordResponse.self)
                #expect(receipt.revision == 1)
            }
            #expect(try await Enrollment.find(id, on: app.db)?.currentRevision == 1)
        }
    }

    @Test(arguments: [0, 2])
    func invalidOrUnreviewedRevisionCannotCreateConsent(reviewedRevision: Int) async throws {
        try await TestApp.withApp(token: .participant(subject: Self.subject)) { app, token in
            let enrollment = try await Self.fixture(on: app)
            let id = try enrollment.requireId()
            let presentation = try await ConsentRequestFixtures.presentation(on: app, enrollmentID: id.uuidString, token: token)
            try await PublishedStudyFixtures.createPublishedStudy(
                on: app.db,
                studyId: enrollment.$study.id,
                revision: 2,
                consentSnapshot: .init([.enUS: PublishedStudyFixtures.requiredConsentMarkdown])
            )
            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(id)/consents", beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeMultipartConsentBody(
                    commandID: UUID(),
                    enrollmentETag: presentation.enrollmentETag,
                    consentData: Self.consentData(),
                    presentation: presentation.presentation,
                    reviewedRevision: reviewedRevision
                )
            }) { response in
                #expect(response.status.code == (reviewedRevision == 0 ? 400 : 409))
            }
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 0)
            #expect(try await Enrollment.find(id, on: app.db)?.currentRevision == 1)
        }
    }

    @Test
    func changedDuplicateCannotReplaceAcceptedEvidence() async throws {
        let commandID = UUID()
        try await TestApp.withApp(token: .participant(subject: Self.subject)) { app, token in
            let enrollment = try await Self.fixture(on: app)
            let id = try enrollment.requireId()
            let path = "\(apiBasePath)/participant/enrollments/\(id)/consents"
            let presentation = try await ConsentRequestFixtures.presentation(on: app, enrollmentID: id.uuidString, token: token)
            try await app.test(.POST, path, beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeMultipartConsentBody(
                    commandID: commandID,
                    enrollmentETag: presentation.enrollmentETag,
                    consentData: Self.consentData(),
                    presentation: presentation.presentation
                )
            }) { response in
                #expect(response.status == .created)
            }
            let accepted = try #require(try await EnrollmentConsent.query(on: app.db).first())
            let originalKey = accepted.evidenceKey
            let originalDigest = accepted.evidenceDigest
            try await app.test(.POST, path, beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeMultipartConsentBody(
                    commandID: commandID,
                    enrollmentETag: presentation.enrollmentETag,
                    consentData: Self.consentData(),
                    presentation: presentation.presentation,
                    pdfData: Data("%PDF changed".utf8)
                )
            }) { response in
                #expect(response.status == .conflict)
            }
            let unchanged = try #require(try await EnrollmentConsent.find(try accepted.requireID(), on: app.db))
            #expect(unchanged.evidenceKey == originalKey)
            #expect(unchanged.evidenceDigest == originalDigest)
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 1)
            try await Self.expectOriginalPDF(on: app, path: "\(path)/\(try accepted.requireID())/pdf", token: token)
        }
    }

    @Test
    func failedAuditCannotAcceptConsentOrAdvanceEnrollment() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.subject)) { app, token in
            let enrollment = try await Self.fixture(on: app)
            let id = try enrollment.requireId()
            let sql = try #require(app.db as? any SQLDatabase)
            let presentation = try await ConsentRequestFixtures.presentation(on: app, enrollmentID: id.uuidString, token: token)
            try await sql.raw("DROP TABLE audit_events").run()
            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(id)/consents", beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeMultipartConsentBody(
                    commandID: UUID(),
                    enrollmentETag: presentation.enrollmentETag,
                    consentData: Self.consentData(),
                    presentation: presentation.presentation
                )
            }) { response in
                #expect(response.status == .internalServerError)
            }
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 0)
            #expect(try await Enrollment.find(id, on: app.db)?.currentRevision == 1)
            #expect(try await Enrollment.find(id, on: app.db)?.stateVersion == enrollment.stateVersion)
        }
    }

    @Test
    func withdrawnEnrollmentHasNoConsentSideEffects() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.subject)) { app, token in
            let enrollment = try await Self.fixture(on: app)
            let presentation = try await ConsentRequestFixtures.presentation(
                on: app, enrollmentID: try enrollment.requireId().uuidString, token: token
            )
            enrollment.withdrawnAt = Date()
            try await enrollment.save(on: app.db)
            let id = try enrollment.requireId()
            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(id)/consents", beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeMultipartConsentBody(
                    commandID: UUID(),
                    enrollmentETag: presentation.enrollmentETag,
                    consentData: Self.consentData(),
                    presentation: presentation.presentation
                )
            }) { response in
                #expect(response.status == .conflict)
            }
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 0)
        }
    }
}


extension ConsentSafetyIntegrationTests {
    private static func expectOriginalPDF(on app: Application, path: String, token: String?) async throws {
        try await app.test(.GET, path, beforeRequest: { $0.bearerAuth(token) }) { response in
            #expect(response.status == .ok)
            #expect(response.body.string == "%PDF-1.4 test")
        }
    }

    @Test
    func incompleteConsentIsRejectedBeforeItCanBlockAcceptance() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.subject)) { app, token in
            let enrollment = try await Self.fixture(on: app)
            let enrollmentID = try enrollment.requireId()
            let presentation = try await ConsentRequestFixtures.presentation(on: app, enrollmentID: enrollmentID.uuidString, token: token)
            let consentID = UUID()
            let acceptedAt = Date(timeIntervalSince1970: 1_750_000_000)
            let responses = UserResponses(toggles: ["agree": true])
            let json = String(decoding: try JSONEncoder().encode(responses), as: UTF8.self)
            let sql = try #require(app.db as? any SQLDatabase)
            await #expect {
                try await sql.raw("""
                    INSERT INTO enrollment_consents (id, enrollment_id, revision, user_responses, created_at, updated_at)
                    VALUES (\(bind: consentID), \(bind: enrollmentID), 1, \(literal: json), \(bind: acceptedAt), \(bind: acceptedAt))
                    """)
                    .run()
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            #expect(try await EnrollmentConsent.find(consentID, on: app.db) == nil)
            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(enrollmentID)/consents", beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeMultipartConsentBody(
                    commandID: UUID(),
                    enrollmentETag: presentation.enrollmentETag,
                    consentData: Self.consentData(),
                    presentation: presentation.presentation
                )
            }) { response in
                #expect(response.status == .created)
            }
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 1)
            #expect(try await Enrollment.find(enrollmentID, on: app.db)?.currentRevision == 1)
        }
    }

    @Test
    func missingReviewedRevisionCannotCreateConsent() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.subject)) { app, token in
            let enrollment = try await Self.fixture(on: app)
            let enrollmentID = try enrollment.requireId()
            let presentation = try await ConsentRequestFixtures.presentation(on: app, enrollmentID: enrollmentID.uuidString, token: token)
            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(enrollmentID)/consents", beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeMultipartConsentBody(
                    commandID: UUID(),
                    enrollmentETag: presentation.enrollmentETag,
                    consentData: Self.consentData(),
                    presentation: presentation.presentation
                )
                let body = String(buffer: request.body)
                    .replacingOccurrences(of: "name=\"reviewedRevision\"", with: "name=\"unknownRevision\"")
                request.body = .init(string: body)
            }) { response in
                #expect(response.status == .badRequest)
            }
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 0)
            #expect(try await Enrollment.find(enrollmentID, on: app.db)?.currentRevision == 1)
        }
    }

    @Test
    func acceptedConsentPersistsCompleteEvidenceReferences() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.subject)) { app, token in
            let enrollment = try await Self.fixture(on: app)
            let enrollmentID = try enrollment.requireId()
            let presentation = try await ConsentRequestFixtures.presentation(on: app, enrollmentID: enrollmentID.uuidString, token: token)
            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(enrollmentID)/consents", beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeMultipartConsentBody(
                    commandID: UUID(),
                    enrollmentETag: presentation.enrollmentETag,
                    consentData: Self.consentData(),
                    presentation: presentation.presentation
                )
            }) { response in
                #expect(response.status == .created)
            }
            let accepted = try #require(try await EnrollmentConsent.query(on: app.db).first())
            let evidenceKey = accepted.evidenceKey
            let evidenceDigest = accepted.evidenceDigest
            let retained = try #require(try await EnrollmentConsent.find(try accepted.requireId(), on: app.db))
            #expect(retained.evidenceKey == evidenceKey)
            #expect(retained.evidenceDigest == evidenceDigest)
            #expect(retained.revision == 1)
            #expect(retained.userResponses == accepted.userResponses)
            #expect(retained.createdAt == accepted.createdAt)
            #expect(retained.presentationProof == accepted.presentationProof)
        }
    }
}


extension ConsentSafetyIntegrationTests {
    private actor UploadCounter: ObjectStorageProvider {
        private(set) var uploads = 0

        func delete(key: String) { }

        func upload(data: Data, key: String, contentType: String) async throws {
            uploads += 1
        }

        func download(key: String, maximumBytes: Int) async throws -> Data {
            throw ServerError.notFound("No accepted evidence exists")
        }

        func ensureBucketExists() async throws {}
        func shutdown() async throws {}
    }

    @Test(arguments: ["identifier", "locale", "digest"])
    func changedPresentationCannotUploadEvidence(field: String) async throws {
        let storage = UploadCounter()
        try await TestApp.withApp(token: .participant(subject: Self.subject), storageProvider: storage) { app, token in
            let enrollment = try await Self.fixture(on: app)
            let id = try enrollment.requireId().uuidString
            let presentation = try await ConsentRequestFixtures.presentation(on: app, enrollmentID: id, token: token)
            var changed = presentation.presentation
            switch field {
            case "identifier": changed.presentationId = UUID().uuidString
            case "locale": changed.locale = "de-DE"
            default: changed.digest = String(repeating: "0", count: 64)
            }
            let submitted = changed
            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(id)/consents", beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeMultipartConsentBody(
                    commandID: UUID(),
                    enrollmentETag: presentation.enrollmentETag,
                    consentData: Self.consentData(),
                    presentation: submitted
                )
            }) { response in
                #expect(response.status == .conflict)
            }
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 0)
            #expect(await storage.uploads == 0)
        }
    }

    @Test
    func missingPresentationCannotUploadEvidence() async throws {
        let storage = UploadCounter()
        try await TestApp.withApp(token: .participant(subject: Self.subject), storageProvider: storage) { app, token in
            let enrollment = try await Self.fixture(on: app)
            let id = try enrollment.requireId().uuidString
            let presentation = try await ConsentRequestFixtures.presentation(on: app, enrollmentID: id, token: token)
            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(id)/consents", beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeMultipartConsentBody(
                    commandID: UUID(),
                    enrollmentETag: presentation.enrollmentETag,
                    consentData: Self.consentData(),
                    presentation: nil
                )
            }) { response in
                #expect(response.status == .badRequest)
            }
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 0)
            #expect(await storage.uploads == 0)
        }
    }

    @Test
    func missingRequiredResponseCannotUploadEvidence() async throws {
        let storage = UploadCounter()
        try await TestApp.withApp(token: .participant(subject: Self.subject), storageProvider: storage) { app, token in
            let enrollment = try await Self.fixture(on: app)
            let id = try enrollment.requireId().uuidString
            let presentation = try await ConsentRequestFixtures.presentation(on: app, enrollmentID: id, token: token)
            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(id)/consents", beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeMultipartConsentBody(
                    commandID: UUID(),
                    enrollmentETag: presentation.enrollmentETag,
                    consentData: ["toggles": [:], "selects": [:], "signatures": [:]],
                    presentation: presentation.presentation
                )
            }) { response in
                #expect(response.status == .badRequest)
            }
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 0)
            #expect(await storage.uploads == 0)
        }
    }

    @Test
    func unavailableLocaleCannotIssuePresentationOrAcceptNewConsent() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.subject)) { app, token in
            let enrollment = try await Self.fixture(on: app)
            let id = try enrollment.requireId().uuidString
            var presentation = try await ConsentRequestFixtures.presentation(on: app, enrollmentID: id, token: token)
            presentation.presentation.locale = "de-DE"
            try await app.test(
                .GET,
                "\(apiBasePath)/participant/enrollments/\(id)/consent-presentation?locale=de-DE",
                beforeRequest: { $0.bearerAuth(token) }
            ) { response in
                #expect(response.status == .conflict)
            }
            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(id)/consents", beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeMultipartConsentBody(
                    commandID: UUID(),
                    enrollmentETag: presentation.enrollmentETag,
                    consentData: Self.consentData(),
                    presentation: presentation.presentation
                )
            }) { response in
                #expect(response.status == .conflict)
            }
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 0)
        }
    }

    @Test
    func rejectedEvidenceMutationPreservesExactReplay() async throws {
        let commandID = UUID()
        try await TestApp.withApp(token: .participant(subject: Self.subject)) { app, token in
            let enrollment = try await Self.fixture(on: app)
            let id = try enrollment.requireId().uuidString
            let presentation = try await ConsentRequestFixtures.presentation(on: app, enrollmentID: id, token: token)
            let path = "\(apiBasePath)/participant/enrollments/\(id)/consents"
            try await app.test(.POST, path, beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeMultipartConsentBody(
                    commandID: commandID,
                    enrollmentETag: presentation.enrollmentETag,
                    consentData: Self.consentData(),
                    presentation: presentation.presentation
                )
            }) { response in
                #expect(response.status == .created)
            }
            let accepted = try #require(try await EnrollmentConsent.query(on: app.db).first())
            let originalKey = accepted.evidenceKey
            accepted.evidenceKey = ""
            await #expect(throws: (any Error).self) {
                try await accepted.save(on: app.db)
            }
            try await app.test(.POST, path, beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeMultipartConsentBody(
                    commandID: commandID,
                    enrollmentETag: presentation.enrollmentETag,
                    consentData: Self.consentData(),
                    presentation: presentation.presentation
                )
            }) { response in
                #expect(response.status == .created)
            }
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 1)
            let retained = try #require(try await EnrollmentConsent.find(try accepted.requireId(), on: app.db))
            #expect(retained.evidenceKey == originalKey)
        }
    }
}
