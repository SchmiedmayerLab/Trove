//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import AsyncHTTPClient
import Foundation
import Testing
@testable import TroveServer
import Vapor


struct RecordingTransferStreamingTests {
    @Test(.enabled(if: Environment.get("TROVE_TEST_S3_PORT") != nil, "Requires a disposable loopback S3 test service"))
    func largeHTTPUploadStreamsToStorageAndRecoversItsReceipt() async throws {
        let port = try #require(Environment.get("TROVE_TEST_S3_PORT").flatMap(Int.init))
        try #require((1024...65535).contains(port))
        let configuration = S3ObjectStorageConfiguration(
            endpoint: "http://127.0.0.1:\(port)",
            accessKeyId: "trove_test",
            secretAccessKey: "trove_test",
            bucket: "trove-http-stream-test-\(UUID().uuidString.lowercased())",
            region: "us-east-1"
        )
        try await TestApp.withS3Storage(configuration: configuration) { provider in
            try await provider.ensureBucketExists()
            try await TestApp.withApp(token: .participant(subject: "test-participant"), storageProvider: provider) { app, token in
                try await Self.upload(on: app, token: token)
            }
        }
    }
}


extension RecordingTransferStreamingTests {
    private static func upload(on app: Application, token: String?) async throws {
        let fixture = try await RecordingTransferHTTPTests.prepare(on: app)
        let client = try RecordingTransferHTTPTests.client(app, token: token)
        let input = GeneratedObjectStorageBody(byteCount: 96 * 1024 * 1024 + 1)
        let digest = try await input.digest(), id = UUID()
        var declaration = RecordingTransferHTTPTests.declaration(fixture)
        declaration.content.storedByteCount = Int64(input.byteCount)
        declaration.content.sourceByteCount = Int64(input.byteCount)
        declaration.content.storedSHA256 = digest
        declaration.content.sourceSHA256 = digest
        _ = try await RecordingTransferHTTPTests.register(client, fixture: fixture, id: id, declaration: declaration)
        try await app.server.start(address: .hostname("127.0.0.1", port: 0))
        do {
            let port = try #require(app.http.server.shared.localAddress?.port)
            let path = RecordingTransferHTTPTests.path(fixture, id: id, operation: "content")
            var request = HTTPClientRequest(url: "http://127.0.0.1:\(port)/\(path)")
            request.method = .PUT
            request.headers.bearerAuthorization = .init(token: try #require(token))
            request.headers.contentType = .binary
            request.headers.add(name: "Trove-Source-Installation-ID", value: fixture.installationID.uuidString)
            request.headers.add(name: "Trove-Source-Credential", value: SourceBindingFixture.credentialBase64(fixture.installationID))
            request.body = .stream(input.map { ByteBuffer(bytes: $0) }, length: .known(Int64(input.byteCount)))
            let baseline = try Self.peakResidentBytes()
            let response = try await app.http.client.shared.execute(request, timeout: .seconds(90))
            _ = try await response.body.collect(upTo: 16 * 1024)
            #expect(response.status == .ok)
            let receipt = try await RecordingTransferHTTPTests.lookup(client, fixture: fixture, id: id)
            #expect(receipt.storedByteCount == Int64(input.byteCount) && receipt.storedSHA256 == digest)
            if let baseline, let peak = try Self.peakResidentBytes() {
                print("HTTP_RECORDING_MEMORY payloadBytes=\(input.byteCount) baselineBytes=\(baseline) peakBytes=\(peak)")
                #expect(peak - baseline < 64 * 1024 * 1024)
            }
            try await RecordingTransferHTTPTests.expectRows(transfers: 1, attempts: 1, receipts: 1, on: app)
            try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
            await app.server.shutdown()
        } catch {
            await app.server.shutdown()
            throw error
        }
    }

    private static func peakResidentBytes() throws -> Int? {
        #if os(Linux)
        let status = try String(contentsOfFile: "/proc/self/status", encoding: .utf8)
        let line = try #require(status.split(separator: "\n").first { $0.hasPrefix("VmHWM:") })
        return try #require(Int(line.split(whereSeparator: \.isWhitespace)[1])) * 1024
        #else
        return nil
        #endif
    }
}
