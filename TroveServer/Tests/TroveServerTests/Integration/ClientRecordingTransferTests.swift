//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import Testing
import TroveAPIClient
@testable import TroveServer
import VaporTesting


/// Real router, source proof and consent admission; small request bodies use the in-process test transport.
/// Artifact custody is deliberately not reported as clinical admission.
struct ClientRecordingTransferTests {
    @Test
    func lostUploadResponseRecoversAcrossRestartAfterSourceRevocationWithoutResending() async throws {
        try await Self.exerciseRecovery(storage: InMemoryObjectStorageProvider())
    }

    @Test(.enabled(if: Environment.get("TROVE_TEST_S3_PORT") != nil, "Requires a disposable loopback S3 test service"))
    func s3ReceiptRecoveryPreservesTheSingleStoredArtifact() async throws {
        let port = try #require(Environment.get("TROVE_TEST_S3_PORT").flatMap(Int.init))
        try #require((1024...65535).contains(port))
        let configuration = S3ObjectStorageConfiguration(
            endpoint: "http://127.0.0.1:\(port)",
            accessKeyId: "trove_test",
            secretAccessKey: "trove_test",
            bucket: "trove-recording-test-\(UUID().uuidString.lowercased())",
            region: "us-east-1"
        )
        try await TestApp.withS3Storage(configuration: configuration) { provider in
            try await provider.ensureBucketExists()
            try await Self.exerciseRecovery(storage: provider)
        }
    }
}


extension ClientRecordingTransferTests {
    private static func exerciseRecovery(storage: any ObjectStorageProvider) async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant"), storageProvider: storage) { app, token in
            let fixture = try await RecordingTransferHTTPTests.prepare(on: app)
            let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("trove-recording-client-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("delivery.sqlite")
            let scope = try EventDeliveryJournal.Scope(
                backend: Servers.Server1.url().absoluteString, issuer: TestApp.issuer, subject: "test-participant"
            )
            let transfer = try await ClientDeliveryRecoveryTests.withJournal(url: url, scope: scope, mode: .createNew) { journal in
                try await SourceBindingFixture.registerJournal(journal, source: fixture.source, query: Data([1]), receiver: (app, token))
                let transfer = try await Self.prepare(journal: journal, fixture: fixture)
                let transport = ReceiverClientTransport(application: app, token: token, loseRecordingResponse: true)
                let drainer = try Self.drainer(journal: journal, transport: transport)
                await #expect(throws: RecordingTransferDrainer.Failure.transportFailed) { try await drainer.transfer(transfer.transferID) }
                #expect(try await journal.recordingTransfer(for: transfer.transferID)?.receipt == nil)
                #expect(await transport.recordingBodies.count == 1)
                return transfer
            }
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await app.grove[SourceBindingService.self].revoke(id: fixture.source.id)
            }
            try await ClientDeliveryRecoveryTests.withJournal(url: url, scope: scope, mode: .openExisting) { journal in
                let transport = ReceiverClientTransport(application: app, token: token)
                let receipt = try await Self.drainer(journal: journal, transport: transport).transfer(transfer.transferID)
                try transfer.commitment.verify(receipt, sourceID: transfer.sourceID, transferID: transfer.transferID)
                #expect(await transport.recordingBodies.isEmpty)
                #expect(await transport.paths.count == 1)
                #expect(try await journal.reclaimRecordingFiles() == 0)
            }
            try await RecordingTransferHTTPTests.expectRows(transfers: 1, attempts: 1, receipts: 1, on: app)
            try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
        }
    }
}


extension ClientRecordingTransferTests {
    private static func drainer(journal: EventDeliveryJournal, transport: ReceiverClientTransport) throws -> RecordingTransferDrainer {
        try .init(
            journal: journal,
            scope: journal.scope,
            client: TroveAPIClient.Client(serverURL: Servers.Server1.url(), configuration: .trove, transport: transport),
            validateSession: {}
        )
    }

    private static func prepare(
        journal: EventDeliveryJournal, fixture: ClinicalEventStoreTests.Fixture
    ) async throws -> DeliveryRecordingTransfer {
        let fixtureURL = try #require(Bundle.module.url(forResource: "HealthKitWorkoutRouteEvent", withExtension: "json"))
        let original = try LocalPointEventFixture.bytes(source: fixture.source, fixtureURL: fixtureURL)
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var entries = try #require(object["entry"] as? [[String: Any]])
        let index = try #require(entries.firstIndex { ($0["resource"] as? [String: Any])?["resourceType"] as? String == "DocumentReference" })
        var document = try #require(entries[index]["resource"] as? [String: Any])
        var content = try #require(document["content"] as? [[String: Any]])
        var attachment = try #require(content[0]["attachment"] as? [String: Any])
        let encoded = try #require(attachment.removeValue(forKey: "data") as? String)
        let bytes = try #require(Data(base64Encoded: encoded))
        var declaration = RecordingTransferHTTPTests.declaration(fixture)
        declaration.outputFullUrl = try #require(entries[index]["fullUrl"] as? String)
        declaration.targets[0].outputFullUrls = [declaration.outputFullUrl]
        declaration.content.storedByteCount = Int64(bytes.count)
        declaration.content.sourceByteCount = Int64(bytes.count)
        declaration.content.storedSHA256 = ArtifactStore.digest(bytes)
        declaration.content.sourceSHA256 = declaration.content.storedSHA256
        attachment["url"] = declaration.attachmentPath
        content[0]["attachment"] = attachment
        document["content"] = content
        entries[index]["resource"] = document
        object["entry"] = entries
        let record = try ExchangeRecord(validating: JSONSerialization.data(withJSONObject: object))
        let checkpoint = try await journal.checkpoint(for: fixture.source.id)
        let payload = EventDeliveryJournal.Payload(
            bytes: record.json,
            targets: [.init(consentID: fixture.consentIDs[0], outputFullURLs: [declaration.outputFullUrl])],
            recordings: [.init(relativePath: declaration.attachmentPath, byteCount: bytes.count) { try $0(bytes) }]
        )
        let ids = try await journal.stage(from: checkpoint, nextCursor: Data([2]), payloads: [payload])
        let id = try #require(ids.first)
        let file = try #require(await journal.recordingReferences(for: id).first)
        return try await journal.prepareRecordingTransfer(recordingID: file.id, deliveryID: id, declaration: declaration)
    }
}
