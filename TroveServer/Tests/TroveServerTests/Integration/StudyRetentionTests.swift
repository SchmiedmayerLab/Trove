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


struct StudyRetentionTests {
    private static func referenceIndexExists(on database: any SQLDatabase) async throws -> Bool {
        let query: SQLQueryString = database.dialect.name == "sqlite"
            ? "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_enrollments_study_id'"
            : "SELECT indexname FROM pg_indexes WHERE schemaname = current_schema() AND indexname = 'idx_enrollments_study_id'"
        let index = try await database.raw(query).first()
        return index != nil
    }

    @Test(arguments: ["/Test Group/researcher", "/Other Group/admin"])
    func unauthorizedDeletionLeavesDraftAndAuditUnchanged(membership: String) async throws {
        try await TestApp.withApp(token: .researcher(groups: [membership])) { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let studyID = try study.requireId()
            try await app.test(.DELETE, "\(apiBasePath)/studies/\(studyID)", beforeRequest: { request in
                request.bearerAuth(token)
                request.headers.replaceOrAdd(name: "If-Match", value: "\"\(study.draftRevision)\"")
            }) { response in
                #expect(response.status == .forbidden)
            }
            #expect(try await Study.find(studyID, on: app.db) != nil)
            let sql = try #require(app.db as? any SQLDatabase)
            let count = try await sql.raw("SELECT count(*) AS count FROM audit_events")
                .first()?
                .decode(column: "count", as: Int.self)
            #expect(count == 0)
        }
    }

    @Test
    func freshSchemaIndexesStudyEnrollmentReferences() async throws {
        try await TestApp.withApp { app, _ in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let participant = try await ParticipantFixtures.createParticipant(on: app.db)
            let enrollment = Enrollment(participantId: try participant.requireId(), studyId: try study.requireId(), currentRevision: 1)
            try await enrollment.save(on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            #expect(try await Self.referenceIndexExists(on: sql))
            #expect(try await Enrollment.find(enrollment.requireId(), on: app.db) != nil)
        }
    }

    @Test(arguments: ["publication", "enrollment", "withdrawn-consent"])
    func retainedStudyRecordsCannotBeCascadeDeleted(record: String) async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let studyID = try study.requireId()
            if record == "publication" {
                try await PublishedStudyFixtures.createPublishedStudy(on: app.db, studyId: studyID)
            } else {
                let participant = try await ParticipantFixtures.createParticipant(on: app.db)
                let enrollment = Enrollment(participantId: try participant.requireId(), studyId: studyID, currentRevision: 1)
                if record == "withdrawn-consent" { enrollment.withdrawnAt = Date() }
                try await enrollment.save(on: app.db)
                if record == "withdrawn-consent" {
                    let consent = try await RetainedRecordFixtures.consent(on: app.db, enrollmentID: enrollment.requireId())
                    try await consent.save(on: app.db)
                }
            }
            try await app.test(.DELETE, "\(apiBasePath)/studies/\(studyID)", beforeRequest: { request in
                request.bearerAuth(token)
                request.headers.replaceOrAdd(name: "If-Match", value: "\"\(study.draftRevision)\"")
            }) { response in
                #expect(response.status == .conflict)
            }
            #expect(try await Study.find(studyID, on: app.db) != nil)
            #expect(try await PublishedStudy.query(on: app.db).count() == (record == "publication" ? 1 : 0))
            #expect(try await Enrollment.query(on: app.db).count() == (record == "publication" ? 0 : 1))
            #expect(try await EnrollmentConsent.query(on: app.db).count() == (record == "withdrawn-consent" ? 1 : 0))
            let sql = try #require(app.db as? any SQLDatabase)
            let count = try await sql.raw("SELECT count(*) AS count FROM audit_events WHERE action = 'study.draft.deleted'")
                .first()?
                .decode(column: "count", as: Int.self)
            #expect(count == 0)
        }
    }

    @Test(arguments: ["groups", "studies", "participants", "enrollments", "invitation_codes"])
    func databaseRejectsDeletionOfConsentAncestors(table: String) async throws {
        try await TestApp.withApp { app, _ in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let participant = try await ParticipantFixtures.createParticipant(on: app.db)
            let invitation = InvitationCode(studyId: try study.requireId(), code: "RETAINED-CONSENT")
            try await invitation.save(on: app.db)
            let enrollment = Enrollment(
                participantId: try participant.requireId(),
                studyId: try study.requireId(),
                currentRevision: 1,
                invitationCodeId: try invitation.requireId()
            )
            try await enrollment.save(on: app.db)
            let consent = try await RetainedRecordFixtures.consent(on: app.db, enrollmentID: enrollment.requireId())
            consent.commandID = UUID()
            consent.expectedEnrollmentVersion = 1
            consent.acceptedEnrollmentVersion = 2
            consent.evidenceKey = "synthetic/retained.pdf"
            consent.evidenceDigest = String(repeating: "a", count: 64)
            try await consent.save(on: app.db)
            let ids = try [
                "groups": group.requireId(), "studies": study.requireId(), "participants": participant.requireId(),
                "enrollments": enrollment.requireId(), "invitation_codes": invitation.requireId()
            ]
            let id = try #require(ids[table])
            let sql = try #require(app.db as? any SQLDatabase)
            await #expect {
                try await sql.raw("DELETE FROM \(ident: table) WHERE id = \(bind: id)").run()
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            let retained = try #require(try await EnrollmentConsent.find(consent.requireId(), on: app.db))
            #expect(retained.commandID == consent.commandID)
            #expect(retained.evidenceKey == consent.evidenceKey)
            #expect(retained.evidenceDigest == consent.evidenceDigest)
            #expect(retained.acceptedEnrollmentVersion == 2)
            #expect(try await Enrollment.find(enrollment.requireId(), on: app.db)?.$invitationCode.id == invitation.requireId())
        }
    }

    @Test(arguments: ["groups", "studies"])
    func databaseRejectsDeletionOfPublicationAncestors(table: String) async throws {
        try await TestApp.withApp { app, _ in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let published = try await PublishedStudyFixtures.createPublishedStudy(on: app.db, studyId: study.requireId())
            let id = try table == "groups" ? group.requireId() : study.requireId()
            let sql = try #require(app.db as? any SQLDatabase)
            await #expect {
                try await sql.raw("DELETE FROM \(ident: table) WHERE id = \(bind: id)").run()
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            let retained = try #require(try await PublishedStudy.find(published.requireId(), on: app.db))
            #expect(retained.bundleKey == published.bundleKey)
            #expect(retained.bundleDigest == published.bundleDigest)
            #expect(try await Study.find(study.requireId(), on: app.db) != nil)
        }
    }

    @Test
    func unusedDraftDeletionRetainsItsAuditRecord() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let studyID = try study.requireId()
            try await app.test(.DELETE, "\(apiBasePath)/studies/\(studyID)", beforeRequest: { request in
                request.bearerAuth(token)
                request.headers.replaceOrAdd(name: "If-Match", value: "\"\(study.draftRevision)\"")
            }) { response in
                #expect(response.status == .noContent)
            }
            #expect(try await Study.find(studyID, on: app.db) == nil)
            let sql = try #require(app.db as? any SQLDatabase)
            let row = try #require(try await sql.raw("SELECT * FROM audit_events WHERE action = 'study.draft.deleted'").first())
            #expect(try row.decode(column: "study_id", as: UUID.self) == studyID)
            #expect(try row.decode(column: "group_id", as: UUID.self) == group.requireId())
            #expect(try row.decode(column: "actor_subject", as: String.self) == "researcher-test-user")
        }
    }

    @Test
    func failedAuditRestoresTheDeletedDraft() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let studyID = try study.requireId()
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("DROP TABLE audit_events").run()
            try await app.test(.DELETE, "\(apiBasePath)/studies/\(studyID)", beforeRequest: { request in
                request.bearerAuth(token)
                request.headers.replaceOrAdd(name: "If-Match", value: "\"\(study.draftRevision)\"")
            }) { response in
                #expect(response.status == .internalServerError)
            }
            #expect(try await Study.find(studyID, on: app.db) != nil)
        }
    }

    @Test
    func deletionRequiresAnExplicitTransactionAndTheAuthorizedGroup() async throws {
        try await TestApp.withApp { app, _ in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let repository = app.grove[StudyRepository.self]
            let studyID = try study.requireId()
            let groupID = try group.requireId()
            await #expect(throws: AuditError.transactionRequired) {
                try await repository.deleteUnusedDraft(id: studyID, expectedGroupID: groupID, on: app.db)
            }
            await #expect {
                try await app.db.transaction { transaction in
                    try await repository.deleteUnusedDraft(id: studyID, expectedGroupID: UUID(), on: transaction)
                }
            } throws: { error in
                (error as? ServerError)?.status.code == 403
            }
            #expect(try await Study.find(studyID, on: app.db) != nil)
        }
    }
}
