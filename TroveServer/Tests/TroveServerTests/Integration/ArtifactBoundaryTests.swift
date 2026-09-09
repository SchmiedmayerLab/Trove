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


struct ArtifactBoundaryTests {
    private static func attachReference(
        _ artifact: ArtifactReference, studyID: UUID, enrollmentID: UUID, on database: any Database
    ) async throws {
        // Simulate inconsistent registry metadata: the domain reference exists while state
        // incorrectly remains ready. Neither acceptance nor normal cleanup creates this state.
        if artifact.purpose == .publication {
            try await PublishedStudyFixtures.createPublishedStudy(on: database, studyId: studyID, artifact: artifact)
        } else {
            let consent = try await RetainedRecordFixtures.consent(on: database, enrollmentID: enrollmentID)
            consent.artifactID = artifact.id
            try await consent.save(on: database)
        }
    }

    @Test(arguments: ["owner", "purpose", "key", "digest", "size"])
    func inconsistentAcceptedMetadataCannotReleaseBytes(field: String) async throws {
        try await TestApp.withApp { app, _ in
            let storage = app.grove[ObjectStorageService.self]
            let store = ArtifactStore(database: app.db, storage: storage)
            let reference = try await store.stage(Data("evidence".utf8), purpose: .consent, ownerID: UUID(), scope: .init(studyID: UUID()))
            try await app.db.transaction { transaction in try await store.retain(reference, on: transaction) }
            // With no object remaining, an attempted provider read would return 404.
            // A 500 here proves the metadata guard rejected the request before storage.
            try await storage.delete(key: reference.key)
            if field == "size" {
                try await StoredArtifact.query(on: app.db).filter(\.$id == reference.id).set(\.$byteCount, to: 0).update()
            }
            await #expect {
                try await store.download(
                    id: reference.id,
                    ownerID: field == "owner" ? UUID() : reference.ownerID,
                    purpose: field == "purpose" ? .publication : .consent,
                    expected: (field == "key" ? "untrusted/key" : reference.key, field == "digest" ? "wrong" : reference.digest)
                )
            } throws: { error in
                (error as? ServerError)?.status.code == 500
            }
        }
    }

    @Test(arguments: [0, 10 * 1024 * 1024 + 1])
    func invalidInputSizeCreatesNeitherObjectNorRecoveryRecord(size: Int) async throws {
        try await TestApp.withApp { app, _ in
            let store = ArtifactStore(database: app.db, storage: app.grove[ObjectStorageService.self])
            await #expect {
                try await store.stage(Data(repeating: 0, count: size), purpose: .consent, ownerID: UUID(), scope: .init(studyID: UUID()))
            } throws: { error in
                (error as? ServerError)?.status.code == 400
            }
            let count = try await StoredArtifact.query(on: app.db).count()
            #expect(count == 0)
        }
    }

    @Test
    func cleanupBatchAdvancesWithoutRemovingRecoveryRecords() async throws {
        try await TestApp.withApp { app, _ in
            let store = ArtifactStore(database: app.db, storage: app.grove[ObjectStorageService.self])
            let started = Date()
            for _ in 0..<3 {
                _ = try await store.stage(Data("evidence".utf8), purpose: .consent, ownerID: UUID(), scope: .init(studyID: UUID()), now: started)
            }
            let due = started.addingTimeInterval(7200)
            let audit = AuditEvent.Context.artifactCleanup(configuration: try .init(applicationRevision: "cleanup-revision"))
            #expect(try await store.cleanup(limit: 2, now: due, auditContext: audit).deleted == 2)
            let sql = try #require(app.db as? any SQLDatabase)
            let rows = try await sql.raw("""
                SELECT actor_issuer, actor_subject, application_revision, correlation_id, initiator_subject FROM audit_events
                """)
                .all()
            #expect(rows.count == 2)
            for row in rows {
                #expect(try row.decode(column: "actor_issuer", as: String.self) == "urn:trove:system")
                #expect(try row.decode(column: "actor_subject", as: String.self) == "artifact-cleanup")
                #expect(try row.decode(column: "application_revision", as: String.self) == "cleanup-revision")
                #expect(try row.decode(column: "correlation_id", as: UUID.self) == audit.correlationID)
                #expect(try row.decode(column: "initiator_subject", as: String?.self) == nil)
            }
            #expect(try await store.cleanup(limit: 2, now: due).deleted == 1)
            #expect(try await store.cleanup(limit: 2, now: due).deleted == 0)
            #expect(try await StoredArtifact.query(on: app.db).count() == 3)
            #expect(try await StoredArtifact.query(on: app.db).filter(\.$state == .discarding).count() == 3)
            await #expect(throws: CreateStoredArtifacts.RollbackError.retainedArtifacts) {
                try await CreateStoredArtifacts().revert(on: app.db)
            }
        }
    }

    @Test(arguments: ["stored_artifact_cleanup", "consent_artifact_reference", "publication_artifact_reference"])
    func freshSchemaCreatesArtifactIndexes(name: String) async throws {
        try await TestApp.withApp { app, _ in
            let sql = try #require(app.db as? any SQLDatabase)
            let query: SQLQueryString = sql.dialect.name == "sqlite"
                ? "SELECT name FROM sqlite_master WHERE type = 'index' AND name = \(bind: name)"
                : "SELECT indexname FROM pg_indexes WHERE schemaname = current_schema() AND indexname = \(bind: name)"
            let index = try await sql.raw(query).first()
            #expect(index != nil)
        }
    }

    @Test
    func linkedPublicationIsProtectedEvenIfRegistryStateIsDamaged() async throws {
        try await TestApp.withApp { app, _ in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let store = ArtifactStore(database: app.db, storage: app.grove[ObjectStorageService.self])
            let reference = try await store.stage(
                Data("archive".utf8), purpose: .publication, ownerID: study.requireId(), scope: .init(studyID: study.requireId())
            )
            try await PublishedStudyFixtures.createPublishedStudy(on: app.db, studyId: study.requireId(), artifact: reference)
            #expect(try await store.cleanup(now: Date().addingTimeInterval(7200)).deleted == 0)
            #expect(try await StoredArtifact.find(reference.id, on: app.db)?.state == .ready)
        }
    }

    @Test(arguments: [ArtifactReference.Purpose.publication, .consent])
    func referencedDamagedRecordDoesNotStarveLaterOrphan(purpose: ArtifactReference.Purpose) async throws {
        try await TestApp.withApp { app, _ in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let studyID = try study.requireId()
            let participant = try await ParticipantFixtures.createParticipant(on: app.db)
            let enrollment = Enrollment(participantId: try participant.requireId(), studyId: studyID, currentRevision: 1)
            try await enrollment.save(on: app.db)
            let storage = app.grove[ObjectStorageService.self]
            let store = ArtifactStore(database: app.db, storage: storage)
            let started = Date()
            let bytes = Data("retained evidence".utf8)
            let referenced = try await store.stage(
                bytes,
                purpose: purpose,
                ownerID: purpose == .publication ? studyID : enrollment.requireId(),
                scope: .init(studyID: studyID),
                now: started
            )
            try await Self.attachReference(referenced, studyID: studyID, enrollmentID: enrollment.requireId(), on: app.db)
            let orphan = try await store.stage(
                Data("orphan".utf8),
                purpose: purpose,
                ownerID: UUID(),
                scope: .init(studyID: studyID),
                now: started.addingTimeInterval(1)
            )
            let report = try await store.cleanup(limit: 1, now: started.addingTimeInterval(7200))
            #expect(report.deleted == 1)
            #expect(report.failed == 0)
            #expect(try await StoredArtifact.find(referenced.id, on: app.db)?.state == .ready)
            #expect(try await storage.download(key: referenced.key) == bytes)
            #expect(try await StoredArtifact.find(orphan.id, on: app.db)?.state == .discarding)
            await #expect(throws: (any Error).self) { try await storage.download(key: orphan.key) }
        }
    }
}
