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
import JWTKit
import SQLKit
import Testing
import TroveAPIClient
@testable import TroveServer
import VaporTesting


struct StudyRecordingFixture: Sendable {
    let source: ClinicalEventStoreTests.Fixture
    let recording: RecordingAttachmentFixture
    let grantID: UUID
    let artifactID: UUID

    static func prepare(on app: Application, token: String?, compressed: Bool = true) async throws -> Self {
        let source = try await RecordingTransferHTTPTests.prepare(on: app)
        let recording = try RecordingAttachmentFixture.make(source: source.source, consentID: source.consentIDs[0], compressed: compressed)
        let receipt = try await ClinicalRecordingAttachmentTests.upload(recording, source: source, on: app, token: token)
        let result = try await ClinicalRecordingAttachmentTests.submit(
            recording.submission(sourceID: source.source.id, receipt: receipt), source: source, on: app, token: token
        )
        let first = try #require(result.first)
        if case .ProblemDetails(let problem) = first {
            Issue.record("Synthetic recording admission failed: status=\(problem.status), detail=\(problem.detail ?? "none")")
            throw ServerError.unexpectedError
        }
        guard case .EventReceipt = first else { throw ServerError.unexpectedError }
        let sql = try #require(app.db as? any SQLDatabase)
        let grant = try #require(try await sql.raw("SELECT id FROM study_data_grants WHERE study_id = \(bind: source.studyIDs[0])").first())
        return try .init(
            source: source,
            recording: recording,
            grantID: grant.decode(column: "id", as: UUID.self),
            artifactID: receipt.artifactId.requireId()
        )
    }

    static func readerToken(
        groups: [String] = ["/Test Group/researcher", "/Test Group/data-reader"], expiration: Date = Date().addingTimeInterval(3600)
    ) async throws -> String {
        let keys = JWTKeyCollection()
        await keys.add(hmac: HMACKey(from: TestApp.testSecret), digestAlgorithm: .sha256, kid: "test-key")
        return try await TestApp.signToken(
            keys: keys, subject: "researcher-test-user", roles: [TestApp.researcherRole], groups: groups, expiration: expiration
        )
    }

    static func disclosureCount(on app: Application) async throws -> Int {
        let sql = try #require(app.db as? any SQLDatabase)
        let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM audit_events WHERE action = 'study.recording.disclosure'").first())
        return try row.decode(column: "count", as: Int.self)
    }

    static func rejectAudit(on app: Application) async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        if app.db is any PostgresDatabase {
            try await sql.raw("""
                CREATE TRIGGER reject_recording_disclosure BEFORE INSERT ON audit_events FOR EACH ROW
                WHEN (NEW.action = 'study.recording.disclosure') EXECUTE FUNCTION trove_reject_audit_mutation()
                """)
                .run()
        } else {
            try await sql.raw("""
                CREATE TRIGGER reject_recording_disclosure BEFORE INSERT ON audit_events
                WHEN NEW.action = 'study.recording.disclosure' BEGIN SELECT RAISE(ABORT, 'Synthetic audit failure'); END
                """)
                .run()
        }
    }

    func withdraw(on app: Application) async throws {
        try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: source.enrollmentIDs[0])
        }
    }

    func retract(on app: Application) async throws {
        let bytes = try RetractionEventFixture.bytes(activeBytes: recording.record)
        let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-only")
        try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            _ = try await ClinicalEventStore(database: app.db).accept(
                event, sourceID: source.source.id, targets: [], installation: source.installation
            )
        }
    }
}
