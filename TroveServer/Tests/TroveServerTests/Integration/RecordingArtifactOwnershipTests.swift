//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import OpenAPIRuntime
import SQLKit
import Testing
@testable import TroveServer


struct RecordingArtifactOwnershipTests {
    private static let bytes = Data("synthetic recording".utf8)
    private static let scope = ParticipantArtifactScope(participantID: UUID(), sourceBindingID: UUID())

    private static func stage(in store: ArtifactStore) async throws -> ArtifactReference {
        try await store.stageRecording(HTTPBody(bytes), digest: ArtifactStore.digest(bytes), scope: scope, maximumBytes: 1024)
    }

    @Test
    func recordingCustodyHasNoStudyAndRetainsItsSourceAfterReload() async throws {
        try await TestApp.withApp { app, _ in
            let store = ArtifactStore(database: app.db, storage: app.grove[ObjectStorageService.self])
            let reference = try await Self.stage(in: store)
            let stored = try #require(try await StoredArtifact.find(reference.id, on: app.db))
            #expect(stored.studyID == nil && stored.groupID == nil)
            #expect(stored.participantID == Self.scope.participantID)
            #expect(stored.sourceBindingID == Self.scope.sourceBindingID)
            #expect(try stored.reference().scope == .participantSource(Self.scope))
            #expect(stored.state == .ready)
            try await app.db.transaction { transaction in try await store.retain(reference, on: transaction) }
            #expect(try await store.cleanup(now: Date().addingTimeInterval(7200)).deleted == 0)
            #expect(try await StoredArtifact.find(reference.id, on: app.db)?.state == .retained)
            await #expect(throws: (any Error).self) {
                try await store.download(
                    id: reference.id, ownerID: reference.ownerID, purpose: .recording, expected: (reference.key, reference.digest)
                )
            }
        }
    }

    @Test(arguments: [true, false])
    func changedOwnershipCannotRetainAReadyObject(changeParticipant: Bool) async throws {
        try await TestApp.withApp { app, _ in
            let store = ArtifactStore(database: app.db, storage: app.grove[ObjectStorageService.self])
            let reference = try await Self.stage(in: store)
            let scope = ParticipantArtifactScope(
                participantID: changeParticipant ? UUID() : Self.scope.participantID,
                sourceBindingID: changeParticipant ? Self.scope.sourceBindingID : UUID()
            )
            let altered = ArtifactReference(
                id: reference.id,
                ownerID: reference.ownerID,
                purpose: .recording,
                digest: reference.digest,
                byteCount: reference.byteCount,
                scope: .participantSource(scope)
            )
            await #expect(throws: (any Error).self) {
                try await app.db.transaction { transaction in try await store.retain(altered, on: transaction) }
            }
            #expect(try await StoredArtifact.find(reference.id, on: app.db)?.state == .ready)
        }
    }

    @Test
    func cleanupAuditsTheParticipantSourceWithoutInventingAStudy() async throws {
        try await TestApp.withApp { app, _ in
            let store = ArtifactStore(database: app.db, storage: app.grove[ObjectStorageService.self])
            let reference = try await Self.stage(in: store)
            #expect(try await store.cleanup(now: Date().addingTimeInterval(7200)).deleted == 1)
            #expect(try await StoredArtifact.find(reference.id, on: app.db)?.state == .discarding)
            let sql = try #require(app.db as? any SQLDatabase)
            let row = try #require(try await sql.raw("SELECT * FROM audit_events WHERE target_id = \(bind: reference.id)").first())
            #expect(try row.decode(column: "action", as: String.self) == AuditEvent.Action.recordingArtifactDiscardScheduled.rawValue)
            #expect(try row.decode(column: "study_id", as: UUID?.self) == nil)
            #expect(try row.decode(column: "group_id", as: UUID?.self) == nil)
            #expect(try row.decode(column: "participant_id", as: UUID.self) == Self.scope.participantID)
            #expect(try row.decode(column: "source_binding_id", as: UUID.self) == Self.scope.sourceBindingID)
        }
    }

    @Test(arguments: [0, -1, 1, Int(Int32.max) + 1])
    func invalidOrExceededLimitsLeaveNoRecoveryRowAndDoNotReadTheBody(limit: Int) async throws {
        try await TestApp.withApp { app, _ in
            let store = ArtifactStore(database: app.db, storage: app.grove[ObjectStorageService.self])
            let source = ObjectStorageStreamSource(["abc"])
            await #expect(throws: (any Error).self) {
                try await store.stageRecording(
                    source.body(length: .known(3)), digest: ArtifactStore.digest(Data("abc".utf8)), scope: Self.scope, maximumBytes: limit
                )
            }
            #expect(await source.reads == 0)
            let count = try await StoredArtifact.query(on: app.db).count()
            #expect(count == 0)
        }
    }

    @Test
    func recordingCannotUseTheStudyStagingEntryPoint() async throws {
        try await TestApp.withApp { app, _ in
            let store = ArtifactStore(database: app.db, storage: app.grove[ObjectStorageService.self])
            await #expect(throws: (any Error).self) {
                try await store.stage(Self.bytes, purpose: .recording, ownerID: Self.scope.participantID, scope: .init(studyID: UUID()))
            }
            let count = try await StoredArtifact.query(on: app.db).count()
            #expect(count == 0)
        }
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func databaseRejectsMixedIncompleteAndMismatchedOwnership(scenario: Int) async throws {
        try await TestApp.withApp { app, _ in
            let store = ArtifactStore(database: app.db, storage: app.grove[ObjectStorageService.self])
            let reference = try await Self.stage(in: store)
            let stored = try #require(try await StoredArtifact.find(reference.id, on: app.db))
            switch scenario {
            case 0: stored.studyID = UUID()
            case 1: stored.groupID = UUID()
            case 2: stored.participantID = nil
            case 3: stored.sourceBindingID = nil
            default: stored.ownerID = UUID()
            }
            await #expect {
                try await stored.update(on: app.db)
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            let persisted = try #require(try await StoredArtifact.find(reference.id, on: app.db))
            #expect(try persisted.reference().scope == reference.scope)
        }
    }
}
