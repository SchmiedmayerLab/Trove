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
import TroveAPIServer
@testable import TroveServer
import Vapor


struct ArtifactS3IntegrationTests {
    /// Uploads a 1 MiB warm-up and then `input` through `upload`, and returns the receipt of `input` with how far the
    /// resident memory sampled during its upload rose above the resident memory after the warm-up.
    ///
    /// The bound covers what the transfer itself adds, not what the process accumulated before it. The warm-up through the
    /// same path first creates the storage client, connection and lazily initialized state that stay resident afterwards,
    /// and leaves the allocator's pools sized for a transfer. The measured upload is then compared with the resident memory
    /// after the warm-up, sampled throughout the transfer: a transfer that buffered the payload instead of streaming it
    /// would hold at least its 96 MiB at once, and an upload that ran ahead of a busy storage connection could queue most
    /// of it.
    private static func uploadAfterWarmUp(
        _ input: GeneratedObjectStorageBody,
        _ declaration: RecordingTransferDeclaration,
        consentID: UUID,
        upload: (GeneratedObjectStorageBody, RecordingTransferDeclaration) async throws -> RecordingTransferReceipt
    ) async throws -> (receipt: RecordingTransferReceipt, growthBytes: Int?) {
        let warmUpInput = GeneratedObjectStorageBody(byteCount: 1024 * 1024 + 1)
        let warmUpDeclaration = try Self.declaration(
            byteCount: warmUpInput.byteCount,
            digest: try await warmUpInput.digest(),
            consentID: consentID,
            output: "urn:uuid:5d0c4f43-6f1e-4c2b-9a51-0f4d4c8f7a21"
        )
        _ = try await upload(warmUpInput, warmUpDeclaration)
        let (receipt, growth) = try await ResidentMemory.growth {
            try await upload(input, declaration)
        }
        return (receipt, growth)
    }

    @Test(.enabled(if: Environment.get("TROVE_TEST_S3_PORT") != nil, "Requires a disposable loopback S3 test service"))
    func largeSidecarStreamsThroughRealStorageWithBoundedMemory() async throws {
        let port = try #require(Environment.get("TROVE_TEST_S3_PORT").flatMap(Int.init))
        try #require((1024...65535).contains(port))
        let configuration = S3ObjectStorageConfiguration(
            endpoint: "http://127.0.0.1:\(port)",
            accessKeyId: "trove_test",
            secretAccessKey: "trove_test",
            bucket: "trove-stream-test-\(UUID().uuidString.lowercased())",
            region: "us-east-1"
        )
        try await TestApp.withS3Storage(configuration: configuration) { provider in
            try await provider.ensureBucketExists()
            try await TestApp.withApp(storageProvider: provider) { app, _ in
                let store = ArtifactStore(database: app.db, storage: app.grove[ObjectStorageService.self])
                let input = GeneratedObjectStorageBody(byteCount: 96 * 1024 * 1024 + 1)
                let digest = try await input.digest()
                let fixture = try await ClinicalEventStoreTests.prepare(
                    on: app, profile: CollectionObservationProfile.workout.rawValue, routeStudies: [0]
                )
                let scope = ParticipantArtifactScope(participantID: fixture.source.participantID, sourceBindingID: fixture.source.id)
                let declaration = try Self.declaration(byteCount: input.byteCount, digest: digest, consentID: fixture.consentIDs[0])
                let service = RecordingTransferService(
                    database: app.db,
                    storage: app.grove[ObjectStorageService.self],
                    limits: try .init(storedBytes: input.byteCount, sourceBytes: input.byteCount)
                )
                let (receipt, growth) = try await Self.uploadAfterWarmUp(input, declaration, consentID: fixture.consentIDs[0]) { input, declaration in
                    try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                        try await service.upload(
                            input.body, sourceID: fixture.source.id, transferID: UUID(), declaration: declaration, installation: fixture.installation
                        )
                    }
                }
                let stored = try #require(try await StoredArtifact.find(receipt.artifactID, on: app.db))
                let reference = try stored.reference()
                #expect(receipt.declarationSHA256 == declaration.sha256 && receipt.storedSHA256 == digest)
                if let growth {
                    print("S3_TRANSFER_MEMORY payloadBytes=\(input.byteCount) residentGrowthBytes=\(growth)")
                    #expect(growth < 64 * 1024 * 1024)
                }
                #expect(stored.state == .ready)
                #expect(stored.byteCount == input.byteCount && stored.digest == digest)
                #expect(try stored.reference().scope == .participantSource(scope))
                // The warm-up and the measured artifact.
                #expect(try await store.cleanup(now: Date().addingTimeInterval(7200)).deleted == 2)
                await #expect(throws: (any Error).self) { try await provider.downloadBody(key: reference.key) }
            }
        }
    }

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


extension ArtifactS3IntegrationTests {
    private static func declaration(
        byteCount: Int,
        digest: String,
        consentID: UUID,
        output: String = "urn:uuid:997260f5-8c97-4cc7-bbe0-46c230c2bf4f"
    ) throws -> RecordingTransferDeclaration {
        let date = Date()
        // Transport verification only; the generated bytes are not a clinically admitted route.
        return try .init(
            attachmentPath: "recordings/route.csv",
            outputFullURL: output,
            profile: FHIRRecordingProjection.profile,
            format: .locationTrackSamples,
            effectiveAt: date,
            effectiveEnd: date,
            content: .init(storedByteCount: byteCount, storedSHA256: digest, sourceByteCount: byteCount, sourceSHA256: digest, encoding: .identity),
            targets: [.init(consentID: consentID, outputFullURLs: [output])]
        )
    }
}
