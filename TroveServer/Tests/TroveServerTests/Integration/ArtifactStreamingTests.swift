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
import Testing
@testable import TroveServer


struct ArtifactStreamingTests {
    @Test
    func streamedArtifactBecomesReadyOnlyAfterExactReadback() async throws {
        try await TestApp.withApp { app, _ in
            let store = ArtifactStore(database: app.db, storage: app.grove[ObjectStorageService.self])
            let source = ObjectStorageStreamSource(["%PDF", "-1.4", " synthetic"])
            let bytes = Data("%PDF-1.4 synthetic".utf8)
            let reference = try await store.stage(
                source.body(length: .known(Int64(bytes.count))),
                digest: ArtifactStore.digest(bytes),
                purpose: .consent,
                ownerID: UUID(),
                scope: .init(studyID: UUID())
            )
            #expect(await source.reads == 4)
            #expect(try await StoredArtifact.find(reference.id, on: app.db)?.state == .ready)
            try await app.db.transaction { transaction in try await store.retain(reference, on: transaction) }
            #expect(try await store.download(
                id: reference.id, ownerID: reference.ownerID, purpose: .consent, expected: (reference.key, reference.digest)
            ) == bytes)
        }
    }

    @Test(arguments: [0, 1, 2, 3])
    func failedTransferKeepsItsRecoveryRecordWithoutAcceptance(scenario: Int) async throws {
        let source = ObjectStorageStreamSource(["abc", "def"], failureAt: scenario == 0 ? 1 : nil)
        try await TestApp.withApp { app, _ in
            let store = ArtifactStore(database: app.db, storage: app.grove[ObjectStorageService.self])
            let count = scenario == 1 ? 5 : scenario == 2 ? 7 : 6
            let digest = ArtifactStore.digest(Data(scenario == 3 ? "wrong".utf8 : "abcdef".utf8))
            await #expect(throws: (any Error).self) {
                try await store.stage(
                    source.body(length: .known(Int64(count))),
                    digest: digest,
                    purpose: .consent,
                    ownerID: UUID(),
                    scope: .init(studyID: UUID())
                )
            }
            let records = try await StoredArtifact.query(on: app.db).all()
            let record = try #require(records.first)
            #expect(records.count == 1 && record.state == .staging)
            let reference = try record.reference()
            await #expect(throws: (any Error).self) {
                try await app.db.transaction { transaction in try await store.retain(reference, on: transaction) }
            }
            #expect(try await store.cleanup(now: Date().addingTimeInterval(7200)).deleted == 1)
            #expect(try await StoredArtifact.find(reference.id, on: app.db)?.state == .discarding)
        }
    }

    @Test
    func invalidDeclarationsDoNotCreateStorageWork() async throws {
        try await TestApp.withApp { app, _ in
            let store = ArtifactStore(database: app.db, storage: app.grove[ObjectStorageService.self])
            let declarations: [(HTTPBody.Length, String)] = [
                (.unknown, ArtifactStore.digest(Data())), (.known(0), ArtifactStore.digest(Data())),
                (.known(Int64(ArtifactReference.Purpose.consent.maximumBytes + 1)), ArtifactStore.digest(Data())),
                (.known(3), "invalid")
            ]
            for (length, digest) in declarations {
                let source = ObjectStorageStreamSource(["abc"])
                await #expect(throws: (any Error).self) {
                    try await store.stage(
                        source.body(length: length), digest: digest, purpose: .consent, ownerID: UUID(), scope: .init(studyID: UUID())
                    )
                }
                #expect(await source.reads == 0)
            }
            let count = try await StoredArtifact.query(on: app.db).count()
            #expect(count == 0)
        }
    }
}
