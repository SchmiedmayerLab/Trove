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
import TroveAPIClient
@testable import TroveServer
import VaporTesting


struct ClinicalRecordingAttachmentTests {
    @Test(arguments: [false, true])
    func acceptedRecordRetainsExactlyItsArtifactAndReplaysWithoutAnotherBinding(compressed: Bool) async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant"), validator: ClinicalEventBatchTests.validator()) { app, token in
            let source = try await RecordingTransferHTTPTests.prepare(on: app)
            let fixture = try RecordingAttachmentFixture.make(source: source.source, consentID: source.consentIDs[0], compressed: compressed)
            let receipt = try await Self.upload(fixture, source: source, on: app, token: token)
            let request = try fixture.submission(sourceID: source.source.id, receipt: receipt)
            let first = try await Self.submit(request, source: source, on: app, token: token)
            guard case .EventReceipt(let accepted) = try #require(first.first) else {
                Issue.record("Recording was not admitted")
                return
            }
            #expect(try await Self.submit(request, source: source, on: app, token: token) == first)
            try await ClinicalEventStoreTests.expectRows(events: 1, nodes: accepted.nodeCount, facts: 1, grants: 1, on: app.db)
            try await Self.expectAttachment(receipt, count: 1, state: .retained, on: app)
            let report = try await ArtifactStore(database: app.db, storage: app.grove[ObjectStorageService.self]).cleanup(
                now: Date().addingTimeInterval(7200)
            )
            #expect(report.deleted == 0 && report.failed == 0)
        }
    }

    @Test(arguments: ["missing", "path", "artifact", "expired", "source-hash", "window", "missing-object", "withdrawn", "audit"])
    func rejectedBindingsCannotRetainAnArtifactOrAdmitClinicalRows(reason: String) async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant"), validator: ClinicalEventBatchTests.validator()) { app, token in
            let source = try await RecordingTransferHTTPTests.prepare(on: app)
            var fixture = try RecordingAttachmentFixture.make(source: source.source, consentID: source.consentIDs[0], compressed: true)
            if reason == "window" {
                let later = Date()
                fixture.declaration.effectiveAt = later
                fixture.declaration.effectiveEnd = later
            }
            if reason == "source-hash" { fixture.declaration.content.sourceSHA256 = String(repeating: "0", count: 64) }
            let receipt = try await Self.upload(fixture, source: source, on: app, token: token)
            var request = try fixture.submission(sourceID: source.source.id, receipt: receipt)
            if reason == "missing" { request.records[0].recordings = nil }
            if reason == "path" { request.records[0].recordings?[0].attachmentPath = "recordings/other.csv" }
            if reason == "artifact" { request.records[0].recordings?[0].artifactId = UUID().uuidString }
            try await Self.invalidatePrerequisite(reason, receipt: receipt, source: source, on: app)
            let result = try await Self.submit(request, source: source, on: app, token: token)
            guard case .ProblemDetails(let problem) = try #require(result.first) else {
                Issue.record("Invalid recording was admitted")
                return
            }
            if ["expired", "missing-object"].contains(reason) {
                #expect(problem.status == 503)
            } else {
                #expect(problem.status >= 400)
            }
            try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
            try await Self.expectAttachment(receipt, count: 0, state: .ready, on: app)
        }
    }
}


extension ClinicalRecordingAttachmentTests {
    static func upload(
        _ fixture: RecordingAttachmentFixture, source: ClinicalEventStoreTests.Fixture, on app: Application, token: String?
    ) async throws -> Components.Schemas.RecordingTransferReceipt {
        let client = try RecordingTransferHTTPTests.client(app, token: token), id = UUID()
        _ = try await RecordingTransferHTTPTests.register(client, fixture: source, id: id, declaration: fixture.declaration)
        return try await client.uploadParticipantRecordingTransfer(.init(
            path: .init(sourceId: source.source.id.uuidString, transferId: id.uuidString),
            headers: .init(
                troveSourceInstallationID: source.installationID.uuidString,
                troveSourceCredential: SourceBindingFixture.credentialBase64(source.installationID)
            ),
            body: .binary(.init(fixture.stored))
        )).ok.body.json
    }

    static func submit(
        _ request: Components.Schemas.RecordBundleSubmission, source: ClinicalEventStoreTests.Fixture, on app: Application, token: String?
    ) async throws -> [Components.Schemas.EventBatchResult] {
        try await RecordingTransferHTTPTests.client(app, token: token).submitParticipantRecordBundle(.init(
            path: .init(sourceId: source.source.id.uuidString),
            headers: .init(
                troveSourceInstallationID: source.installationID.uuidString,
                troveSourceCredential: SourceBindingFixture.credentialBase64(source.installationID)
            ),
            body: .json(request)
        )).ok.body.json
    }

    static func expectAttachment(
        _ receipt: Components.Schemas.RecordingTransferReceipt, count: Int, state: StoredArtifact.State, on app: Application
    ) async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM clinical_recording_attachments").first())
        #expect(try row.decode(column: "count", as: Int.self) == count)
        #expect(try await StoredArtifact.find(UUID(uuidString: receipt.artifactId), on: app.db)?.state == state)
    }

    private static func invalidatePrerequisite(
        _ reason: String, receipt: Components.Schemas.RecordingTransferReceipt, source: ClinicalEventStoreTests.Fixture, on app: Application
    ) async throws {
        switch reason {
        case "expired":
            try await StoredArtifact.query(on: app.db)
                .filter(\.$id == receipt.artifactId.requireId())
                .set(\.$expiresAt, to: Date().addingTimeInterval(-1))
                .update()
        case "missing-object":
            let artifact = try #require(try await StoredArtifact.find(UUID(uuidString: receipt.artifactId), on: app.db))
            try await app.grove[ObjectStorageService.self].delete(key: artifact.reference().key)
        case "withdrawn":
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: source.enrollmentIDs[0])
            }
        case "audit":
            try await rejectAudit(on: app)
        default:
            break
        }
    }

    private static func rejectAudit(on app: Application) async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        if app.db is any PostgresDatabase {
            try await sql.raw("""
                CREATE TRIGGER reject_recording_custody_audit BEFORE INSERT ON audit_events FOR EACH ROW
                WHEN (NEW.action = 'clinical.event.accepted') EXECUTE FUNCTION trove_reject_audit_mutation()
                """)
                .run()
        } else {
            try await sql.raw("""
                CREATE TRIGGER reject_recording_custody_audit BEFORE INSERT ON audit_events
                WHEN NEW.action = 'clinical.event.accepted'
                BEGIN SELECT RAISE(ABORT, 'Synthetic audit failure'); END
                """)
                .run()
        }
    }
}
