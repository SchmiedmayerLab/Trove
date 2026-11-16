//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPIClient
@testable import TroveServer
import VaporTesting


/// Real client journal, upload drainer, Bundle transport and receiver transaction; a synthetic validator supplies shape acceptance.
struct ClientRecordingAdmissionTests {
    @Test(arguments: [false, true])
    func lostClinicalReplyRecoversAfterRevocationAndOnlyThenReleasesTheFile(compressed: Bool) async throws {
        try await Self.exerciseRecovery(compressed: compressed, storage: InMemoryObjectStorageProvider())
    }

    @Test(.enabled(if: Environment.get("TROVE_TEST_S3_PORT") != nil, "Requires a disposable loopback S3 test service"))
    func compressedS3RecordingGainsClinicalCustodyBeforeClientFileReclamation() async throws {
        let port = try #require(Environment.get("TROVE_TEST_S3_PORT").flatMap(Int.init))
        try #require((1024...65535).contains(port))
        let configuration = S3ObjectStorageConfiguration(
            endpoint: "http://127.0.0.1:\(port)",
            accessKeyId: "trove_test",
            secretAccessKey: "trove_test",
            bucket: "trove-admission-test-\(UUID().uuidString.lowercased())",
            region: "us-east-1"
        )
        try await TestApp.withS3Storage(configuration: configuration) { provider in
            try await provider.ensureBucketExists()
            try await Self.exerciseRecovery(compressed: true, storage: provider)
        }
    }
}


extension ClientRecordingAdmissionTests {
    private static func exerciseRecovery(compressed: Bool, storage: any ObjectStorageProvider) async throws {
        try await TestApp.withApp(
            token: .participant(subject: "test-participant"), storageProvider: storage, validator: ClinicalEventBatchTests.validator()
        ) { app, token in
            let source = try await RecordingTransferHTTPTests.prepare(on: app)
            let fixture = try RecordingAttachmentFixture.make(source: source.source, consentID: source.consentIDs[0], compressed: compressed)
            let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("trove-recording-admission-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("delivery.sqlite")
            let scope = try EventDeliveryJournal.Scope(
                backend: Servers.Server1.url().absoluteString, issuer: TestApp.issuer, subject: "test-participant"
            )
            let staged = try await ClientDeliveryRecoveryTests.withJournal(url: url, scope: scope, mode: .createNew) { journal in
                try await SourceBindingFixture.registerJournal(journal, source: source.source, query: Data([1]), receiver: (app, token))
                return try await Self.loseClinicalReply(fixture, journal: journal, on: app, token: token)
            }
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await app.grove[SourceBindingService.self].revoke(id: source.source.id)
            }
            try await ClientDeliveryRecoveryTests.withJournal(url: url, scope: scope, mode: .openExisting) { journal in
                let transport = ReceiverClientTransport(application: app, token: token)
                let drainer = try Self.drainer(journal, transport: transport, now: { Date().addingTimeInterval(600) })
                _ = try await drainer.drain()
                #expect(try await journal.status(for: staged.deliveryID) == .delivered)
                #expect(await transport.recordingBodies.isEmpty)
                #expect(await transport.batchBodies.isEmpty)
                #expect(await transport.paths.count == 1)
                #expect(try await journal.reclaimRecordingFiles() == 1)
            }
            try await ClinicalRecordingAttachmentTests.expectAttachment(staged.receipt, count: 1, state: .retained, on: app)
            try await RecordingTransferHTTPTests.expectRows(transfers: 1, attempts: 1, receipts: 1, on: app)
        }
    }
}


extension ClientRecordingAdmissionTests {
    private struct Staged: Sendable {
        let deliveryID: UUID
        let receipt: Components.Schemas.RecordingTransferReceipt
    }

    private static func loseClinicalReply(
        _ fixture: RecordingAttachmentFixture, journal: EventDeliveryJournal, on app: Application, token: String?
    ) async throws -> Staged {
        let sourceID = try #require(await journal.sourceSetups().first?.binding?.source.id).requireId()
        let payload = EventDeliveryJournal.Payload(
            bytes: fixture.record,
            targets: try fixture.declaration.targets.map { .init(consentID: try $0.consentId.requireId(), outputFullURLs: $0.outputFullUrls) },
            recordings: [.init(relativePath: fixture.declaration.attachmentPath, byteCount: fixture.stored.count) { try $0(fixture.stored) }]
        )
        let checkpoint = try await journal.checkpoint(for: sourceID)
        let id = try #require(await journal.stage(from: checkpoint, nextCursor: Data([2]), payloads: [payload]).first)
        let file = try #require(await journal.recordingReferences(for: id).first)
        _ = try await journal.prepareRecordingTransfer(recordingID: file.id, deliveryID: id, declaration: fixture.declaration)
        let transport = ReceiverClientTransport(application: app, token: token, loseBatchResponse: true)
        _ = try await drainer(journal, transport: transport).drain()
        if case .waiting(let deadline) = try await journal.status(for: id) {
            #expect(deadline > Date())
        } else {
            Issue.record("A lost clinical reply must retain a retry deadline")
        }
        #expect(await transport.recordingBodies == [fixture.stored])
        #expect(await transport.batchBodies.count == 1)
        #expect(try await journal.reclaimRecordingFiles() == 0)
        let receipt = try #require(await journal.recordingTransfer(for: file.id)?.receipt)
        try await ClinicalRecordingAttachmentTests.expectAttachment(receipt, count: 1, state: .retained, on: app)
        return Staged(deliveryID: id, receipt: receipt)
    }

    private static func drainer(
        _ journal: EventDeliveryJournal, transport: ReceiverClientTransport, now: @escaping @Sendable () -> Date = { Date() }
    ) throws -> EventDeliveryDrainer {
        try .init(
            journal: journal,
            scope: journal.scope,
            client: TroveAPIClient.Client(serverURL: Servers.Server1.url(), configuration: .trove, transport: transport),
            validateSession: {},
            now: now
        )
    }
}
