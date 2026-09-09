//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import GroveStudyDefinition
import SQLKit
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


private actor AdoptionEvidenceStorage: ObjectStorageProvider {
    private var objects: [String: Data] = [:]
    private var nextUpload: (@Sendable () async throws -> Void)?
    private let corruptUploads: Bool
    private(set) var uploads = 0

    init(corruptUploads: Bool = false) {
        self.corruptUploads = corruptUploads
    }

    func afterNextUpload(_ action: @escaping @Sendable () async throws -> Void) {
        nextUpload = action
    }

    func upload(data: Data, key: String, contentType: String) async throws {
        uploads += 1
        objects[key] = corruptUploads ? data + Data("corrupt".utf8) : data
        let action = nextUpload
        nextUpload = nil
        try await action?()
    }

    func download(key: String, maximumBytes: Int = 50 * 1024 * 1024) throws -> Data {
        guard let data = objects[key] else { throw ServerError.notFound("Synthetic evidence not found") }
        return data
    }

    func ensureBucketExists() {}
    func delete(key: String) { objects.removeValue(forKey: key) }
    func shutdown() {}
}


struct ConsentAdoptionIntegrationTests {
    private struct Context: Sendable {
        let enrollmentID: UUID
        let studyID: UUID
        let participantID: UUID
    }

    private struct Submission: Sendable {
        let presentation: Components.Schemas.ConsentPresentationResponse
        var commandID = UUID()
        var reviewedRevision: Int?
        var agree = true

        func send(
            on app: Application, context: Context, token: String?, expecting status: HTTPStatus
        ) async throws -> Components.Schemas.ConsentRecordResponse? {
            var receipt: Components.Schemas.ConsentRecordResponse?
            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(context.enrollmentID)/consents", beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeMultipartConsentBody(
                    commandID: commandID,
                    enrollmentETag: presentation.enrollmentETag,
                    consentData: ["toggles": ["agree": agree], "selects": [:], "signatures": [:]],
                    presentation: presentation.presentation,
                    reviewedRevision: reviewedRevision ?? presentation.revision
                )
            }) { response in
                try #require(response.status == status)
                if status == .created {
                    receipt = try response.content.decode(Components.Schemas.ConsentRecordResponse.self)
                } else {
                    #expect(!response.body.string.contains("userResponses"))
                    #expect(!response.body.string.contains("%PDF"))
                }
            }
            return receipt
        }
    }

    private static let subject = "consent-adoption-participant"

    @Test
    func publicationAfterReviewDoesNotReplaceReviewedRevision() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.subject)) { app, token in
            let context = try await Self.fixture(on: app)
            let reviewed = try await Self.presentation(context, on: app, token: token)
            try await Self.publish(context, revision: 2, on: app)
            let stillCurrent = try await Self.presentation(context, on: app, token: token)
            #expect(stillCurrent.revision == 1)
            #expect(stillCurrent.presentation == reviewed.presentation)
            let command = Submission(presentation: reviewed)
            let receipt = try #require(try await command.send(on: app, context: context, token: token, expecting: .created))
            #expect(receipt.revision == 1)
            try await Self.expectState(context, revision: 1, version: 2, consentCount: 1, on: app)
        }
    }

    @Test
    func explicitAdoptionRequiresFreshConsentAndReplaysOriginalReceipt() async throws {
        let storage = AdoptionEvidenceStorage()
        try await TestApp.withApp(token: .participant(subject: Self.subject), storageProvider: storage) { app, token in
            let context = try await Self.fixture(on: app)
            let first = Submission(presentation: try await Self.presentation(context, on: app, token: token))
            let original = try #require(try await first.send(on: app, context: context, token: token, expecting: .created))
            try await Self.publish(context, revision: 2, on: app)
            let review = try await Self.presentation(context, on: app, token: token, revision: 2)
            #expect(review.markdown == first.presentation.markdown)
            var incomplete = Submission(presentation: review)
            incomplete.agree = false
            _ = try await incomplete.send(on: app, context: context, token: token, expecting: .badRequest)
            #expect(await storage.uploads == 1)
            let adoption = Submission(presentation: review)
            let accepted = try #require(try await adoption.send(on: app, context: context, token: token, expecting: .created))
            let replay = try #require(try await adoption.send(on: app, context: context, token: token, expecting: .created))
            #expect(accepted.id == replay.id)
            #expect(accepted.revision == 2 && accepted.acceptedEnrollmentVersion == 3)
            let historical = try #require(try await first.send(on: app, context: context, token: token, expecting: .created))
            #expect(historical.id == original.id && historical.acceptedEnrollmentVersion == 2)
            try await Self.expectState(context, revision: 2, version: 3, consentCount: 2, on: app)
            #expect(await storage.uploads == 2)
            let sql = try #require(app.db as? any SQLDatabase)
            let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM audit_events WHERE action = 'consent.recorded'").first())
            #expect(try row.decode(column: "count", as: Int.self) == 2)
            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(context.enrollmentID)/withdraw", beforeRequest: { $0.bearerAuth(token) }) {
                try #require($0.status == .ok)
            }
            let withdrawn = try #require(try await Enrollment.find(context.enrollmentID, on: app.db))
            let withdrawnReplay = try #require(try await adoption.send(on: app, context: context, token: token, expecting: .created))
            #expect(withdrawnReplay.id == accepted.id && withdrawnReplay.acceptedEnrollmentVersion == 3)
            let retained = try #require(try await Enrollment.find(context.enrollmentID, on: app.db))
            #expect(retained.currentRevision == 2 && retained.stateVersion == 4)
            #expect(retained.withdrawnAt != nil && retained.withdrawnAt == withdrawn.withdrawnAt)
            #expect(retained.updatedAt == withdrawn.updatedAt)
            #expect(await storage.uploads == 2)
        }
    }

    @Test
    func newerPublicationDuringStagingDoesNotChangeExplicitTarget() async throws {
        let storage = AdoptionEvidenceStorage()
        try await TestApp.withApp(token: .participant(subject: Self.subject), storageProvider: storage) { app, token in
            let context = try await Self.fixture(on: app)
            try await Self.publish(context, revision: 2, on: app)
            let review = try await Self.presentation(context, on: app, token: token, revision: 2)
            await storage.afterNextUpload { try await Self.publish(context, revision: 3, on: app) }
            let receipt = try #require(try await Submission(presentation: review).send(on: app, context: context, token: token, expecting: .created))
            #expect(receipt.revision == 2)
            try await Self.expectState(context, revision: 2, version: 2, consentCount: 1, on: app)
        }
    }
}


extension ConsentAdoptionIntegrationTests {
    @Test(arguments: [
        ("stale", 412), ("downgrade", 409), ("wrong-target", 409), ("criterion", 403),
        ("missing-invitation", 403), ("foreign-invitation", 403), ("missing-snapshot", 409), ("missing-publication", 404)
    ])
    func invalidAdoptionFailsBeforeEvidenceUpload(failure: String, status: Int) async throws {
        let storage = AdoptionEvidenceStorage()
        try await TestApp.withApp(token: .participant(subject: Self.subject), storageProvider: storage) { app, token in
            let context = try await Self.fixture(on: app)
            let review = try await Self.invalidTargetReview(failure, context: context, on: app, token: token)
            let enrollment = try #require(try await Enrollment.find(context.enrollmentID, on: app.db))
            try await Self.invalidate(failure, context: context, enrollment: enrollment, on: app)
            var command = Submission(presentation: review)
            command.reviewedRevision = failure == "wrong-target" ? 3 : 2
            _ = try await command.send(on: app, context: context, token: token, expecting: .init(statusCode: status))
            try await Self.expectState(context, revision: enrollment.currentRevision, version: enrollment.stateVersion, consentCount: 0, on: app)
            #expect(await storage.uploads == 0)
        }
    }

    @Test
    func retainedInvitationStillAuthorizesAdoptionAfterExpiry() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.subject)) { app, token in
            let context = try await Self.fixture(on: app)
            try await PublishedStudyFixtures.createPublishedStudy(
                on: app.db, studyId: context.studyID, revision: 2, enrollmentCondition: .requiresInvitationCode
            )
            let code = InvitationCode(studyId: context.studyID, code: "RETAINED", expiresAt: Date(timeIntervalSince1970: 1))
            try await code.save(on: app.db)
            let enrollment = try #require(try await Enrollment.find(context.enrollmentID, on: app.db))
            enrollment.$invitationCode.id = try code.requireId()
            try await enrollment.save(on: app.db)
            let review = try await Self.presentation(context, on: app, token: token, revision: 2)
            _ = try await Submission(presentation: review).send(on: app, context: context, token: token, expecting: .created)
            try await Self.expectState(context, revision: 2, version: 2, consentCount: 1, on: app)
            #expect(try await Enrollment.find(context.enrollmentID, on: app.db)?.$invitationCode.id == code.requireId())
        }
    }

    @Test
    func eligibilityChangeDuringStagingCannotAdvanceEnrollment() async throws {
        let storage = AdoptionEvidenceStorage()
        try await TestApp.withApp(token: .participant(subject: Self.subject), storageProvider: storage) { app, token in
            let context = try await Self.fixture(on: app)
            try await PublishedStudyFixtures.createPublishedStudy(
                on: app.db, studyId: context.studyID, revision: 2, participationCriterion: .isFromRegion(.init("US"))
            )
            let review = try await Self.presentation(context, on: app, token: token, revision: 2)
            await storage.afterNextUpload {
                let participant = try #require(try await Participant.find(context.participantID, on: app.db))
                participant.region = "CA"
                try await participant.save(on: app.db)
            }
            _ = try await Submission(presentation: review).send(on: app, context: context, token: token, expecting: .forbidden)
            try await Self.expectState(context, revision: 1, version: 1, consentCount: 0, on: app)
        }
    }

    @Test(arguments: ["corrupt-evidence", "audit"])
    func failedAcceptanceRetainsRevisionAndVersion(failure: String) async throws {
        let storage = AdoptionEvidenceStorage(corruptUploads: failure == "corrupt-evidence")
        try await TestApp.withApp(token: .participant(subject: Self.subject), storageProvider: storage) { app, token in
            let context = try await Self.fixture(on: app)
            try await Self.publish(context, revision: 2, on: app)
            let review = try await Self.presentation(context, on: app, token: token, revision: 2)
            if failure == "audit" {
                try await app.db.schema("audit_events").delete()
            }
            _ = try await Submission(presentation: review).send(
                on: app, context: context, token: token, expecting: failure == "audit" ? .internalServerError : .conflict
            )
            try await Self.expectState(context, revision: 1, version: 1, consentCount: 0, on: app)
        }
    }

    @Test(arguments: ["removed", "changed"])
    func publicationCannotBeRemovedOrChangedDuringStaging(change: String) async throws {
        let storage = AdoptionEvidenceStorage()
        try await TestApp.withApp(token: .participant(subject: Self.subject), storageProvider: storage) { app, token in
            let context = try await Self.fixture(on: app)
            let target = try await Self.publish(context, revision: 2, on: app)
            let review = try await Self.presentation(context, on: app, token: token, revision: 2)
            await storage.afterNextUpload {
                if change == "removed" {
                    await #expect(throws: (any Error).self) { try await target.delete(on: app.db) }
                } else {
                    target.consentSnapshot = .init([.enUS: PublishedStudyFixtures.requiredConsentMarkdown + "\nDifferent approved text."])
                    await #expect(throws: (any Error).self) { try await target.save(on: app.db) }
                }
            }
            _ = try await Submission(presentation: review).send(on: app, context: context, token: token, expecting: .created)
            try await Self.expectState(context, revision: 2, version: 2, consentCount: 1, on: app)
        }
    }
}


extension ConsentAdoptionIntegrationTests {
    @Test(arguments: [("adoption", 412), ("withdrawal", 409)])
    func competingTransitionDuringStagingWinsWithoutExtraAcceptance(winner: String, status: Int) async throws {
        let storage = AdoptionEvidenceStorage()
        try await TestApp.withApp(token: .participant(subject: Self.subject), storageProvider: storage) { app, token in
            let context = try await Self.fixture(on: app)
            try await Self.publish(context, revision: 2, on: app)
            try await Self.publish(context, revision: 3, on: app)
            let command = Submission(presentation: try await Self.presentation(context, on: app, token: token, revision: 2))
            let next = Submission(presentation: try await Self.presentation(context, on: app, token: token, revision: 3))
            await storage.afterNextUpload {
                if winner == "adoption" {
                    _ = try await next.send(on: app, context: context, token: token, expecting: .created)
                } else {
                    let path = "\(apiBasePath)/participant/enrollments/\(context.enrollmentID)/withdraw"
                    try await app.test(.POST, path, beforeRequest: { $0.bearerAuth(token) }) { try #require($0.status == .ok) }
                }
            }
            _ = try await command.send(on: app, context: context, token: token, expecting: .init(statusCode: status))
            let enrollment = try #require(try await Enrollment.find(context.enrollmentID, on: app.db))
            #expect(enrollment.currentRevision == (winner == "adoption" ? 3 : 1))
            #expect(enrollment.stateVersion == 2)
            #expect((enrollment.withdrawnAt != nil) == (winner == "withdrawal"))
            let rejectedCount = try await EnrollmentConsent.query(on: app.db).filter(\.$commandID == command.commandID).count()
            #expect(rejectedCount == 0)
            let count = try await EnrollmentConsent.query(on: app.db).count()
            #expect(count == (winner == "adoption" ? 1 : 0))
            let sql = try #require(app.db as? any SQLDatabase)
            let audits = try await sql.raw("SELECT action, target_version FROM audit_events").all()
            try #require(audits.count == 1)
            #expect(try audits[0].decode(column: "action", as: String.self) == (winner == "adoption" ? "consent.recorded" : "enrollment.withdrawn"))
            #expect(try audits[0].decode(column: "target_version", as: String.self) == (winner == "adoption" ? "3" : "2"))
            #expect(await storage.uploads == (winner == "adoption" ? 2 : 1))
        }
    }

    @Test(arguments: [(0, 400), (-1, 400), (1, 409), (3, 404)])
    func invalidPresentationRevisionQueryIsRejected(revision: Int, status: Int) async throws {
        try await TestApp.withApp(token: .participant(subject: Self.subject)) { app, token in
            let context = try await Self.fixture(on: app)
            try await Self.publish(context, revision: 2, on: app)
            let enrollment = try #require(try await Enrollment.find(context.enrollmentID, on: app.db))
            enrollment.currentRevision = 2
            try await enrollment.save(on: app.db)
            let path = "\(apiBasePath)/participant/enrollments/\(context.enrollmentID)/consent-presentation?locale=en-US&revision=\(revision)"
            try await app.test(.GET, path, beforeRequest: { $0.bearerAuth(token) }) { response in
                #expect(response.status.code == status)
                #expect(!response.body.string.contains("markdown"))
            }
            try await Self.expectState(context, revision: 2, version: 1, consentCount: 0, on: app)
        }
    }
}


extension ConsentAdoptionIntegrationTests {
    private static func fixture(on app: Application) async throws -> Context {
        let group = try await GroupFixtures.createGroup(on: app.db)
        let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
        let participant = try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: subject)
        let enrollment = Enrollment(participantId: try participant.requireId(), studyId: try study.requireId(), currentRevision: 1)
        try await enrollment.save(on: app.db)
        let context = Context(enrollmentID: try enrollment.requireId(), studyID: try study.requireId(), participantID: try participant.requireId())
        try await publish(context, revision: 1, on: app)
        return context
    }

    @discardableResult
    private static func publish(_ context: Context, revision: Int, on app: Application) async throws -> PublishedStudy {
        try await PublishedStudyFixtures.createPublishedStudy(
            on: app.db,
            studyId: context.studyID,
            revision: revision,
            consentSnapshot: .init([.enUS: PublishedStudyFixtures.requiredConsentMarkdown])
        )
    }

    private static func presentation(
        _ context: Context, on app: Application, token: String?, revision: Int? = nil
    ) async throws -> Components.Schemas.ConsentPresentationResponse {
        try await ConsentRequestFixtures.presentation(on: app, enrollmentID: context.enrollmentID.uuidString, token: token, revision: revision)
    }

    private static func expectState(_ context: Context, revision: Int, version: Int64, consentCount: Int, on app: Application) async throws {
        let enrollment = try #require(try await Enrollment.find(context.enrollmentID, on: app.db))
        #expect(enrollment.currentRevision == revision)
        #expect(enrollment.stateVersion == version)
        #expect(enrollment.withdrawnAt == nil)
        let count = try await EnrollmentConsent.query(on: app.db).filter(\.$enrollment.$id == context.enrollmentID).count()
        #expect(count == consentCount)
    }

    private static func invalidTargetReview(
        _ failure: String, context: Context, on app: Application, token: String?
    ) async throws -> Components.Schemas.ConsentPresentationResponse {
        if failure == "missing-publication" {
            return try await presentation(context, on: app, token: token)
        }
        let requiresInvitation = ["missing-invitation", "foreign-invitation"].contains(failure)
        try await PublishedStudyFixtures.createPublishedStudy(
            on: app.db,
            studyId: context.studyID,
            revision: 2,
            enrollmentCondition: requiresInvitation ? .requiresInvitationCode : .none,
            consentSnapshot: failure == "missing-snapshot" ? .init([:]) : .init([.enUS: PublishedStudyFixtures.requiredConsentMarkdown]),
            participationCriterion: failure == "criterion" ? .any([]) : .all([])
        )
        // A missing target/variant cannot issue proof: send another valid revision's proof
        // deliberately, to verify the exact target is rejected before uploading evidence.
        return try await presentation(context, on: app, token: token, revision: failure == "missing-snapshot" ? 1 : 2)
    }

    private static func invalidate(_ failure: String, context: Context, enrollment: Enrollment, on app: Application) async throws {
        switch failure {
        case "stale": enrollment.stateVersion += 1
        case "downgrade": enrollment.currentRevision = 3
        case "wrong-target":
            try await publish(context, revision: 3, on: app)
        case "foreign-invitation":
            let study = try #require(try await Study.find(context.studyID, on: app.db))
            let foreign = try await StudyFixtures.createStudy(on: app.db, groupId: study.$group.id)
            let code = InvitationCode(studyId: try foreign.requireId(), code: "FOREIGN")
            try await code.save(on: app.db)
            enrollment.$invitationCode.id = try code.requireId()
        default: break
        }
        try await enrollment.save(on: app.db)
    }
}
