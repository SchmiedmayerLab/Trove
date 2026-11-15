//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import class OpenAPIRuntime.HTTPBody
import Testing
import TroveAPIClient
@testable import TroveServer
import VaporTesting


/// Runs one deterministic competing operation after storage was read but before clinical custody starts.
private actor AdmissionStorage: BufferedTestObjectStorageProvider {
    private let storage = InMemoryObjectStorageProvider()
    private var action: (@Sendable () async throws -> Void)?
    private(set) var readCount = 0

    func afterRead(_ action: @escaping @Sendable () async throws -> Void) {
        self.action = action
        readCount = 0
    }

    func uploadBuffered(data: Data, key: String, contentType: String) async throws {
        try await storage.upload(data: data, key: key, contentType: contentType)
    }

    func downloadBuffered(key: String, maximumBytes: Int) async throws -> Data {
        let bytes = try await storage.download(key: key, maximumBytes: maximumBytes)
        readCount += 1
        let action = self.action
        self.action = nil
        try await action?()
        return bytes
    }

    func delete(key: String) async throws { try await storage.delete(key: key) }
    func ensureBucketExists() {}
    func shutdown() {}
}


struct ClinicalRecordingRaceTests {
    @Test(arguments: ["withdrawn", "expired", "cleanup"])
    func authorityOrStorageLossDuringReadingCannotGainCustody(reason: String) async throws {
        let storage = AdmissionStorage()
        try await TestApp.withApp(
            token: .participant(subject: "test-participant"), storageProvider: storage, validator: ClinicalEventBatchTests.validator()
        ) { app, token in
            let source = try await RecordingTransferHTTPTests.prepare(on: app)
            let fixture = try RecordingAttachmentFixture.make(source: source.source, consentID: source.consentIDs[0], compressed: true)
            let receipt = try await ClinicalRecordingAttachmentTests.upload(fixture, source: source, on: app, token: token)
            await storage.afterRead {
                if reason == "withdrawn" {
                    _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: source.enrollmentIDs[0])
                } else if reason == "expired" {
                    try await StoredArtifact.query(on: app.db)
                        .filter(\.$id == receipt.artifactId.requireId())
                        .set(\.$expiresAt, to: Date().addingTimeInterval(-1))
                        .update()
                } else {
                    let report = try await ArtifactStore(database: app.db, storage: app.grove[ObjectStorageService.self])
                        .cleanup(now: Date().addingTimeInterval(7200))
                    #expect(report.deleted == 1)
                }
            }
            let result = try await ClinicalRecordingAttachmentTests.submit(
                fixture.submission(sourceID: source.source.id, receipt: receipt), source: source, on: app, token: token
            )
            guard case .ProblemDetails(let problem) = try #require(result.first) else {
                Issue.record("Recording gained custody after losing authority or storage")
                return
            }
            #expect(problem.status == (reason == "withdrawn" ? 403 : 503))
            #expect(await storage.readCount == 1)
            try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
            try await ClinicalRecordingAttachmentTests.expectAttachment(
                receipt, count: 0, state: reason == "cleanup" ? .discarding : .ready, on: app
            )
        }
    }

    @Test
    func anotherParticipantCannotAttachAKnownTransferOrReadItsObject() async throws {
        let storage = AdmissionStorage()
        try await TestApp.withApp(
            token: .participant(subject: "test-participant"), storageProvider: storage, validator: ClinicalEventBatchTests.validator()
        ) { app, token in
            let owner = try await RecordingTransferHTTPTests.prepare(on: app)
            let fixture = try RecordingAttachmentFixture.make(source: owner.source, consentID: owner.consentIDs[0], compressed: true)
            let receipt = try await ClinicalRecordingAttachmentTests.upload(fixture, source: owner, on: app, token: token)
            let original = ClinicalEventStoreTests.participant
            let other = AuthContext(
                issuer: original.issuer,
                subject: "other-participant",
                email: "other@example.invalid",
                roles: original.roles,
                groups: [],
                researcherRole: original.researcherRole,
                participantRole: original.participantRole
            )
            _ = try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: other.subject)
            await storage.afterRead { Issue.record("Foreign recording object was read") }
            try await AuthContext.$current.withValue(other) {
                let installationID = UUID()
                let source = try await app.grove[SourceBindingService.self].registerSource(registrationID: installationID)
                let request = try RecordingAttachmentFixture.make(source: source, consentID: owner.consentIDs[0], compressed: true)
                await #expect {
                    try await app.grove[ClinicalEventService.self].accept(
                        body: HTTPBody(request.record),
                        sourceID: source.id,
                        targets: request.declaration.targets.map { try $0.domainTarget },
                        installation: SourceBindingFixture.proof(installationID),
                        attachments: [
                            .init(attachmentPath: request.declaration.attachmentPath, transferId: receipt.transferId, artifactId: receipt.artifactId)
                        ]
                    )
                } throws: { ($0 as? ServerError)?.status.code == 404 }
            }
            #expect(await storage.readCount == 0)
            try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
            try await ClinicalRecordingAttachmentTests.expectAttachment(receipt, count: 0, state: .ready, on: app)
        }
    }

    @Test
    func referencedRecordingSurvivesCleanupEvenWithDamagedRegistryState() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant"), validator: ClinicalEventBatchTests.validator()) { app, token in
            let source = try await RecordingTransferHTTPTests.prepare(on: app)
            let fixture = try RecordingAttachmentFixture.make(source: source.source, consentID: source.consentIDs[0], compressed: false)
            let receipt = try await ClinicalRecordingAttachmentTests.upload(fixture, source: source, on: app, token: token)
            let result = try await ClinicalRecordingAttachmentTests.submit(
                fixture.submission(sourceID: source.source.id, receipt: receipt), source: source, on: app, token: token
            )
            guard case .EventReceipt = try #require(result.first) else {
                Issue.record("Recording was not admitted")
                return
            }
            try await StoredArtifact.query(on: app.db)
                .filter(\.$id == receipt.artifactId.requireId())
                .set(\.$state, to: .ready)
                .set(\.$cleanupAfter, to: Date().addingTimeInterval(-1))
                .update()
            let report = try await ArtifactStore(database: app.db, storage: app.grove[ObjectStorageService.self]).cleanup()
            #expect(report.deleted == 0 && report.failed == 0)
            try await ClinicalRecordingAttachmentTests.expectAttachment(receipt, count: 1, state: .ready, on: app)
            let artifact = try #require(try await StoredArtifact.find(UUID(uuidString: receipt.artifactId), on: app.db))
            let bytes = try await app.grove[ObjectStorageService.self].download(key: artifact.reference().key)
            #expect(bytes == fixture.stored)
        }
    }
}
