//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import Testing
@testable import TroveServer
import Vapor


struct ArtifactS3IntegrationTests {
    @Test(.enabled(if: Environment.get("TROVE_TEST_S3_PORT") != nil, "Requires a disposable loopback S3 test service"))
    func uploadVerificationBoundedReadAndCleanupUseRealStorage() async throws {
        let port = try #require(Environment.get("TROVE_TEST_S3_PORT").flatMap(Int.init))
        try #require((1024...65535).contains(port))
        // Never read deployment storage credentials or allow a remote endpoint.
        let configuration = S3ObjectStorageConfiguration(
            endpoint: "http://127.0.0.1:\(port)",
            accessKeyId: "trove_test",
            secretAccessKey: "trove_test",
            bucket: "trove-artifact-test-\(UUID().uuidString.lowercased())",
            region: "us-east-1"
        )
        try await TestApp.withS3Storage(configuration: configuration) { provider in
            try await provider.ensureBucketExists()
            try await TestApp.withApp(storageProvider: provider) { app, _ in
                let store = ArtifactStore(database: app.db, storage: app.grove[ObjectStorageService.self])
                let bytes = Data("synthetic consent evidence".utf8)
                let reference = try await store.stage(bytes, purpose: .consent, ownerID: UUID(), scope: .init(studyID: UUID()))
                #expect(try await provider.download(key: reference.key, maximumBytes: bytes.count) == bytes)
                await #expect {
                    try await provider.download(key: reference.key, maximumBytes: bytes.count - 1)
                } throws: { error in
                    (error as? ServerError)?.status.code == 500
                }
                let report = try await store.cleanup(now: Date().addingTimeInterval(7200))
                #expect(report.deleted == 1)
                #expect(report.failed == 0)
                await #expect(throws: (any Error).self) { try await provider.download(key: reference.key, maximumBytes: bytes.count) }
                #expect(try await StoredArtifact.find(reference.id, on: app.db)?.state == .discarding)
                // Deleting a missing object must remain safe on the next sweep.
                #expect(try await store.cleanup(now: Date().addingTimeInterval(14400)).deleted == 1)
            }
        }
    }
}
