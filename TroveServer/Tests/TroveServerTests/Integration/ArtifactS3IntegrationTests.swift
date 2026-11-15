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
    private static func peakResidentBytes() throws -> Int? {
        #if os(Linux)
        let status = try String(contentsOfFile: "/proc/self/status", encoding: .utf8)
        let line = try #require(status.split(separator: "\n").first { $0.hasPrefix("VmHWM:") })
        let kibibytes = try #require(Int(line.split(whereSeparator: \.isWhitespace)[1]))
        return kibibytes * 1024
        #else
        return nil
        #endif
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
                let baseline = try Self.peakResidentBytes()
                let receipt = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                    try await service.upload(
                        input.body, sourceID: fixture.source.id, transferID: UUID(), declaration: declaration, installation: fixture.installation
                    )
                }
                let stored = try #require(try await StoredArtifact.find(receipt.artifactID, on: app.db))
                let reference = try stored.reference()
                #expect(receipt.declarationSHA256 == declaration.sha256 && receipt.storedSHA256 == digest)
                if let baseline, let peak = try Self.peakResidentBytes() {
                    print("S3_TRANSFER_MEMORY payloadBytes=\(input.byteCount) baselineBytes=\(baseline) peakBytes=\(peak)")
                    #expect(peak - baseline < 64 * 1024 * 1024)
                }
                #expect(stored.state == .ready)
                #expect(stored.byteCount == input.byteCount && stored.digest == digest)
                #expect(try stored.reference().scope == .participantSource(scope))
                #expect(try await store.cleanup(now: Date().addingTimeInterval(7200)).deleted == 1)
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
    private static func declaration(byteCount: Int, digest: String, consentID: UUID) throws -> RecordingTransferDeclaration {
        let output = "urn:uuid:997260f5-8c97-4cc7-bbe0-46c230c2bf4f"
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
