//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Synchronization
import Testing
@testable import TroveServer
import Vapor


struct ArtifactStoragePolicyTests {
    @Test(arguments: ["Enabled", "Suspended", "Denied"])
    func unsafeOrUnknownVersioningCannotReachDelete(versioning: String) async throws {
        let requests = Mutex((versioning: 0, deletion: 0))
        let app = try await TestApp.makeApplication()
        app.get("fixture") { _ in
            requests.withLock { $0.versioning += 1 }
            let xml = versioning == "Denied"
                ? "<Error><Code>AccessDenied</Code><Message>Denied</Message></Error>"
                : "<VersioningConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Status>\(versioning)</Status></VersioningConfiguration>"
            return Response(
                status: versioning == "Denied" ? .forbidden : .ok,
                headers: ["Content-Type": "application/xml"],
                body: .init(string: xml)
            )
        }
        app.delete("fixture", "unused") { _ in
            requests.withLock { $0.deletion += 1 }
            return Response(status: .noContent)
        }
        let server = app.server
        var provider: S3ObjectStorageProvider?
        do {
            try await server.start(address: .hostname("127.0.0.1", port: 0))
            let port = try #require(app.http.server.shared.localAddress?.port)
            let configured = try S3ObjectStorageProvider(application: app, config: .init(
                endpoint: "http://127.0.0.1:\(port)",
                accessKeyId: "synthetic-key",
                secretAccessKey: "synthetic-secret",
                bucket: "fixture",
                region: "us-east-1"
            ))
            provider = configured
            do {
                try await configured.delete(key: "unused")
                Issue.record("Unsafe or unknown bucket versioning permitted deletion")
            } catch {
                if versioning != "Denied" {
                    #expect((error as? ServerError)?.status.code == 409)
                }
            }
            #expect(requests.withLock { $0.versioning } == 1)
            #expect(requests.withLock { $0.deletion } == 0)
            try await configured.shutdown()
            provider = nil
            await server.shutdown()
            try await app.asyncShutdown()
        } catch {
            try? await provider?.shutdown()
            await server.shutdown()
            try? await app.asyncShutdown()
            throw error
        }
    }
}
