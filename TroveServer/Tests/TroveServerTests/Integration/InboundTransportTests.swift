//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import NIOConcurrencyHelpers
import Testing
@testable import TroveServer
import Vapor


struct InboundTransportTests {
    @Test(arguments: [
        (["TroveServer"], true, false),
        (["TroveServer", "serve", "--hostname", "migrate"], true, false),
        (["TroveServer", "serve", "--hostname", "cleanup-artifacts"], true, false),
        (["TroveServer", "migrate", "--yes"], false, true),
        (["TroveServer", "revert", "--yes"], false, true),
        (["TroveServer", "cleanup-artifacts"], false, false)
    ])
    func onlyExplicitOperatorCommandsSkipServingIdentity(arguments: [String], serving: Bool, migration: Bool) {
        let environment = Environment(name: "production", arguments: arguments)
        #expect(environment.isServing == serving)
        #expect(environment.isDatabaseMigration == migration)
    }

    @Test(arguments: [
        (nil, nil), ("/certificate.pem", nil), (nil, "/key.pem")
    ] as [(String?, String?)])
    func productionRequiresBothIdentityFiles(certificate: String?, key: String?) {
        #expect(throws: InboundTransportConfiguration.Failure.missingIdentity) {
            try InboundTransportConfiguration(environment: .production, certificateFile: certificate, privateKeyFile: key)
        }
    }

    @Test
    func developmentOnlyPermitsPlaintextWhenNeitherFileIsSpecified() throws {
        #expect(try InboundTransportConfiguration(environment: .development, certificateFile: nil, privateKeyFile: nil).tls == nil)
        #expect(throws: InboundTransportConfiguration.Failure.missingIdentity) {
            try InboundTransportConfiguration(environment: .development, certificateFile: nil, privateKeyFile: "/key.pem")
        }
    }

    @Test(arguments: ["", "relative.pem", "/missing/trove-serving-identity.pem"], AppEnvironment.allCases)
    func invalidPathsCannotFallBackToPlaintext(path: String, environment: AppEnvironment) {
        #expect(throws: InboundTransportConfiguration.Failure.invalidIdentity) {
            try InboundTransportConfiguration(environment: environment, certificateFile: path, privateKeyFile: path)
        }
    }

    @Test(arguments: [Data(), Data("not PEM".utf8), Data(repeating: 65, count: 1_048_577)], [true, false])
    func invalidIdentityContentsFailStartup(bytes: Data, replaceCertificate: Bool) throws {
        let identity = try TransportCertificates()
        _ = try Self.withIdentityFiles(
            certificate: replaceCertificate ? bytes : identity.certificate,
            key: replaceCertificate ? identity.privateKey : bytes
        ) { certificate, key in
            #expect(throws: InboundTransportConfiguration.Failure.invalidIdentity) {
                try InboundTransportConfiguration(environment: .production, certificateFile: certificate, privateKeyFile: key)
            }
        }
    }

    @Test
    func mismatchedKeyFailsBeforeServing() throws {
        let identity = try TransportCertificates()
        let other = try TransportCertificates()
        _ = try Self.withIdentityFiles(certificate: identity.certificate, key: other.privateKey) { certificate, key in
            #expect(throws: InboundTransportConfiguration.Failure.invalidIdentity) {
                try InboundTransportConfiguration(environment: .production, certificateFile: certificate, privateKeyFile: key)
            }
        }
    }

    @Test
    func encryptedPEMCannotPromptForAPassword() throws {
        let identity = try TransportCertificates()
        // A synthetic encrypted PEM envelope, not a retained private key.
        let encrypted = """
        -----BEGIN RSA PRIVATE KEY-----
        Proc-Type: 4,ENCRYPTED
        DEK-Info: AES-128-CBC,00000000000000000000000000000000

        \(Data(repeating: 0, count: 32).base64EncodedString())
        -----END RSA PRIVATE KEY-----
        """
        _ = try Self.withIdentityFiles(certificate: identity.certificate, key: Data(encrypted.utf8)) { certificate, key in
            #expect(throws: InboundTransportConfiguration.Failure.invalidIdentity) {
                try InboundTransportConfiguration(environment: .production, certificateFile: certificate, privateKeyFile: key)
            }
        }
    }

    @Test
    func productionServesVerifiedHTTPSAndRejectsPlaintext() async throws {
        let identity = try TransportCertificates()
        let policy = try Self.withIdentityFiles(certificate: identity.certificate, key: identity.privateKey) { certificate, key in
            try InboundTransportConfiguration(environment: .production, certificateFile: certificate, privateKeyFile: key)
        }
        // The configuration owns parsed identity bytes, not paths reopened while serving.
        #expect(policy.tls?.minimumTLSVersion == .tlsv12)
        let app = try await Application.make(.testing)
        let authority = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: authority) }
        let requests = NIOLockedValueBox(0)
        do {
            try identity.authority.write(to: authority)
            try OutboundTransportConfiguration(environment: .production, certificateAuthorityFile: authority.path).configure(app)
            policy.configure(app)
            app.get("health") { _ in
                requests.withLockedValue { $0 += 1 }
                return "ready"
            }
            try await app.server.start(address: .hostname("127.0.0.1", port: 0))
            let port = try #require(app.http.server.shared.localAddress?.port)
            let response = try await app.client.get(URI(string: "https://127.0.0.1:\(port)/health"))
            #expect(response.status == .ok)
            #expect(response.body?.getString(at: 0, length: 5) == "ready")
            await #expect(throws: (any Error).self) {
                try await app.client.get(URI(string: "http://127.0.0.1:\(port)/health"))
            }
            #expect(requests.withLockedValue { $0 } == 1)
            await app.server.shutdown()
            try await app.asyncShutdown()
        } catch {
            await app.server.shutdown()
            try? await app.asyncShutdown()
            throw error
        }
    }
}


extension InboundTransportTests {
    private static func withIdentityFiles<Value>(
        certificate: Data, key: Data, body: (String, String) throws -> Value
    ) throws -> Value {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let certificateFile = directory.appendingPathComponent("tls.crt")
        let keyFile = directory.appendingPathComponent("tls.key")
        try certificate.write(to: certificateFile)
        try key.write(to: keyFile)
        return try body(certificateFile.path, keyFile.path)
    }
}
