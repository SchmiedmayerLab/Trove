//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import FluentPostgresDriver
import Foundation
import SQLKit
import Testing
@testable import TroveServer


struct ImmutableEvidenceSchemaTests {
    @Test(arguments: ["publication", "consent"], ["empty-key", "long-key", "short-digest", "uppercase-digest", "nonhex-digest"])
    func invalidEvidenceLocatorsAndDigestsCannotBeInserted(kind: String, invalid: String) async throws {
        try await TestApp.withApp { app, _ in
            let (publication, consent) = try await Self.records(on: app.db)
            let key = invalid == "empty-key" ? "" : String(repeating: "k", count: 1025)
            let digest: String
            switch invalid {
            case "short-digest": digest = String(repeating: "a", count: 63)
            case "uppercase-digest": digest = String(repeating: "A", count: 64)
            default: digest = String(repeating: "g", count: 64)
            }
            if kind == "publication" {
                if invalid.hasSuffix("key") { publication.bundleKey = key } else { publication.bundleDigest = digest }
                await #expect {
                    try await publication.save(on: app.db)
                } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            } else {
                if invalid.hasSuffix("key") { consent.evidenceKey = key } else { consent.evidenceDigest = digest }
                await #expect {
                    try await consent.save(on: app.db)
                } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            }
            #expect(try await PublishedStudy.query(on: app.db).count() == 0)
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 0)
        }
    }

    @Test(arguments: ["published_studies", "enrollment_consents"])
    func acceptedEvidenceCannotBeChangedDeletedOrTruncated(table: String) async throws {
        try await TestApp.withApp { app, _ in
            let (publication, consent) = try await Self.records(on: app.db)
            try await publication.save(on: app.db)
            try await consent.save(on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            // Even a valid no-op UPDATE must be refused independently of field constraints.
            await #expect {
                try await sql.raw("UPDATE \(ident: table) SET revision = revision").run()
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            await #expect {
                try await sql.raw("DELETE FROM \(ident: table)").run()
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            if app.db is any PostgresDatabase {
                // Include dependent tables so foreign-key preflight cannot mask the
                // append-only trigger. This application owns an isolated test database.
                await #expect {
                    try await sql.raw("TRUNCATE \(ident: table) CASCADE").run()
                } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            }
            if table == "published_studies" {
                await #expect(throws: CreatePublishedStudies.RollbackError.retainedEvidence) {
                    try await CreatePublishedStudies().revert(on: app.db)
                }
            } else {
                await #expect(throws: CreateEnrollmentConsents.RollbackError.retainedEvidence) {
                    try await CreateEnrollmentConsents().revert(on: app.db)
                }
            }
            #expect(try await PublishedStudy.query(on: app.db).count() == 1)
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 1)
            #expect(try await EnrollmentConsent.find(consent.requireId(), on: app.db)?.commandID == consent.commandID)
        }
    }
}


extension ImmutableEvidenceSchemaTests {
    private static func records(on database: any Database) async throws -> (PublishedStudy, EnrollmentConsent) {
        let group = try await GroupFixtures.createGroup(on: database)
        let study = try await StudyFixtures.createStudy(on: database, groupId: group.requireId())
        let participant = try await ParticipantFixtures.createParticipant(on: database)
        let enrollment = Enrollment(participantId: try participant.requireId(), studyId: try study.requireId(), currentRevision: 1)
        try await enrollment.save(on: database)
        let publication = try await PublishedStudyFixtures.createPublishedStudy(on: database, studyId: study.requireId(), save: false)
        let consent = try await RetainedRecordFixtures.consent(on: database, enrollmentID: enrollment.requireId())
        return (publication, consent)
    }
}
