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


struct EnrollmentSchemaTests {
    private static let subject = "enrollment-command-participant"

    @Test
    func freshEnrollmentDefaultsToInitialVersion() async throws {
        try await TestApp.withApp { app, _ in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let participant = try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.subject)
            let enrollmentID = UUID()
            let acceptedAt = Date(timeIntervalSince1970: 1_750_000_000)
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("""
                INSERT INTO enrollments (id, participant_id, study_id, current_revision, participation_data, created_at, updated_at)
                VALUES (\(bind: enrollmentID), \(bind: participant.requireId()), \(bind: study.requireId()), 3,
                        \(literal: "{}"), \(bind: acceptedAt), \(bind: acceptedAt))
                """)
                .run()
            let enrollment = try #require(try await Enrollment.find(enrollmentID, on: app.db))
            #expect(enrollment.stateVersion == 1)
            #expect(enrollment.currentRevision == 3)
            #expect(enrollment.createdAt == acceptedAt && enrollment.updatedAt == acceptedAt)
        }
    }

    @Test(arguments: [Int64(0), -1])
    func enrollmentVersionMustBePositive(version: Int64) async throws {
        try await TestApp.withApp { app, _ in
            let enrollment = try await Self.enrollment(on: app)
            enrollment.stateVersion = version
            await #expect {
                try await enrollment.save(on: app.db)
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            let retained = try #require(try await Enrollment.find(enrollment.requireId(), on: app.db))
            #expect(retained.stateVersion == 1)
        }
    }

    @Test
    func commandIdentityIsUniqueWithinEnrollment() async throws {
        try await TestApp.withApp { app, _ in
            let enrollment = try await Self.enrollment(on: app)
            let commandID = UUID()
            let first = try await RetainedRecordFixtures.consent(on: app.db, enrollmentID: enrollment.requireId())
            first.commandID = commandID
            try await first.save(on: app.db)
            let duplicate = try await RetainedRecordFixtures.consent(on: app.db, enrollmentID: enrollment.requireId(), revision: 2)
            duplicate.commandID = commandID
            duplicate.expectedEnrollmentVersion = 2
            duplicate.acceptedEnrollmentVersion = 3
            await #expect {
                try await duplicate.save(on: app.db)
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            let count = try await EnrollmentConsent.query(on: app.db).count()
            #expect(count == 1)
        }
    }

    @Test(arguments: [(Int64(0), Int64(1)), (1, 1), (1, 3), (2, 1)])
    func consentReceiptRequiresOnePositiveVersionAdvance(expected: Int64, accepted: Int64) async throws {
        try await TestApp.withApp { app, _ in
            let enrollment = try await Self.enrollment(on: app)
            let consent = try await RetainedRecordFixtures.consent(on: app.db, enrollmentID: enrollment.requireId())
            consent.expectedEnrollmentVersion = expected
            consent.acceptedEnrollmentVersion = accepted
            await #expect {
                try await consent.save(on: app.db)
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 0)
        }
    }

    @Test
    func oneEnrollmentTransitionCannotHaveTwoConsentReceipts() async throws {
        try await TestApp.withApp { app, _ in
            let enrollment = try await Self.enrollment(on: app)
            let first = try await RetainedRecordFixtures.consent(on: app.db, enrollmentID: enrollment.requireId())
            try await first.save(on: app.db)
            let duplicate = try await RetainedRecordFixtures.consent(on: app.db, enrollmentID: enrollment.requireId(), revision: 2)
            await #expect {
                try await duplicate.save(on: app.db)
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 1)
            duplicate.expectedEnrollmentVersion = 2
            duplicate.acceptedEnrollmentVersion = 3
            try await duplicate.save(on: app.db)
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 2)
        }
    }

    @Test(arguments: ["enrollments", "enrollment_consents", "published_studies"], [0, -1])
    func studyRevisionMustBePositive(table: String, revision: Int) async throws {
        try await TestApp.withApp { app, _ in
            let enrollment = try await Self.enrollment(on: app)
            let consent = try await RetainedRecordFixtures.consent(on: app.db, enrollmentID: enrollment.requireId())
            let publication = try await PublishedStudyFixtures.createPublishedStudy(on: app.db, studyId: enrollment.$study.id, save: false)
            await #expect {
                switch table {
                case "enrollments":
                    enrollment.currentRevision = revision
                    try await enrollment.save(on: app.db)
                case "enrollment_consents":
                    consent.revision = revision
                    try await consent.save(on: app.db)
                default:
                    publication.revision = revision
                    try await publication.save(on: app.db)
                }
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            #expect(try await Enrollment.find(enrollment.requireId(), on: app.db)?.currentRevision == 1)
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 0)
            #expect(try await PublishedStudy.query(on: app.db).count() == 0)
        }
    }
}


extension EnrollmentSchemaTests {
    private static func enrollment(on app: Application) async throws -> Enrollment {
        let group = try await GroupFixtures.createGroup(on: app.db)
        let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
        let participant = try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: subject)
        let enrollment = Enrollment(participantId: try participant.requireId(), studyId: try study.requireId(), currentRevision: 1)
        try await enrollment.save(on: app.db)
        return enrollment
    }

    @Test
    func withdrawalAdvancesCurrentStateInsteadOfStudyRevision() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.subject)) { app, token in
            let enrollment = try await Self.enrollment(on: app)
            enrollment.stateVersion = 3
            try await enrollment.save(on: app.db)
            let id = try enrollment.requireId()
            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(id)/withdraw", beforeRequest: { $0.bearerAuth(token) }) {
                #expect($0.status == .ok)
            }
            let retained = try #require(try await Enrollment.find(id, on: app.db))
            #expect(retained.stateVersion == 4)
            #expect(retained.currentRevision == 1)
            #expect(retained.withdrawnAt != nil)
            let sql = try #require(app.db as? any SQLDatabase)
            let row = try #require(try await sql.raw("SELECT target_version FROM audit_events WHERE action = 'enrollment.withdrawn'").first())
            #expect(try row.decode(column: "target_version", as: String.self) == "4")
        }
    }

    @Test
    func withdrawalCannotOverflowEnrollmentVersion() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.subject)) { app, token in
            let enrollment = try await Self.enrollment(on: app)
            enrollment.stateVersion = Int64.max
            try await enrollment.save(on: app.db)
            let id = try enrollment.requireId()
            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(id)/withdraw", beforeRequest: { $0.bearerAuth(token) }) {
                #expect($0.status == .conflict)
            }
            let retained = try #require(try await Enrollment.find(id, on: app.db))
            #expect(retained.stateVersion == Int64.max)
            #expect(retained.withdrawnAt == nil)
            let sql = try #require(app.db as? any SQLDatabase)
            let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM audit_events").first())
            #expect(try row.decode(column: "count", as: Int.self) == 0)
        }
    }
}
