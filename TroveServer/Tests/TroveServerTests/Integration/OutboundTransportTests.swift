//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import AsyncHTTPClient
import Foundation
import NIOConcurrencyHelpers
import NIOSSL
import Testing
@testable import TroveServer
import Vapor


struct OutboundTransportTests {
    @Test(arguments: [
        "http://identity.example.test", "http://127.0.0.1:8080", "ftp://identity.example.test",
        "https://user:secret@identity.example.test", "https://identity.example.test?secret=value",
        "https://identity.example.test#fragment", "https:///", "/relative", "https://identity.example.test:0",
        "https://identity.example.test:65536", "https://identity.example.test/with space", "https://identity.example.test\n"
    ])
    func productionRejectsUnsafeEndpoints(endpoint: String) throws {
        let policy = try OutboundTransportConfiguration(environment: .production)
        #expect(throws: OutboundTransportConfiguration.Failure.invalidEndpoint) {
            try policy.validateEndpoint(endpoint)
        }
    }

    @Test
    func developmentPermitsHTTPButRetainsTLSVerification() throws {
        let policy = try OutboundTransportConfiguration(environment: .development)
        #expect(try policy.validateEndpoint("http://keycloak:8080").host == "keycloak")
        #expect(policy.tls.certificateVerification == .fullVerification)
        #expect(policy.tls.minimumTLSVersion == .tlsv12)
        #expect(policy.tls.trustRoots == .default)
    }

    @Test(arguments: ["", "relative.pem", "/missing/trove-test-ca.pem"])
    func invalidCAPathCannotFallBackToSystemTrust(path: String) {
        #expect(throws: OutboundTransportConfiguration.Failure.invalidCertificateAuthority) {
            try OutboundTransportConfiguration(environment: .production, certificateAuthorityFile: path)
        }
    }

    @Test(arguments: [Data(), Data("not a certificate".utf8), Data(repeating: 65, count: 1_048_577)])
    func invalidCAContentsFailStartup(bytes: Data) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: OutboundTransportConfiguration.Failure.invalidCertificateAuthority) {
            try OutboundTransportConfiguration(environment: .production, certificateAuthorityFile: file.path)
        }
    }

    @Test
    func allServiceClientsRequireConfiguredTransportAndSecureProductionEndpoints() async throws {
        let app = try await Application.make(.testing)
        do {
            #expect(throws: OutboundTransportConfiguration.Failure.notConfigured) {
                try FHIRValidationClient(application: app, endpoint: nil, identity: nil)
            }
            try OutboundTransportConfiguration(environment: .production).configure(app)
            #expect(throws: OutboundTransportConfiguration.Failure.invalidEndpoint) {
                try KeycloakClient(application: app, config: Self.keycloak(endpoint: "http://127.0.0.1:1"))
            }
            #expect(throws: OutboundTransportConfiguration.Failure.invalidEndpoint) {
                try S3ObjectStorageProvider(application: app, config: Self.storage(endpoint: "http://127.0.0.1:1"))
            }
            for endpoint in ["http://127.0.0.1:1/validate", "https://validator.example.test/other"] {
                #expect(throws: OutboundTransportConfiguration.Failure.invalidEndpoint) {
                    try FHIRValidationClient(application: app, endpoint: endpoint, identity: nil)
                }
            }
            let unavailable = try FHIRValidationClient(application: app, endpoint: nil, identity: "sha256:" + String(repeating: "0", count: 64))
            await #expect(throws: (any Error).self) { try await unavailable.validate(Data("{}".utf8)) }
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test(arguments: ["trusted", "wrong-host", "expired", "unknown-ca"])
    func serviceClientsEnforceCertificateTrustAndHostname(certificate: String) async throws {
        let requests = NIOLockedValueBox(0)
        try await Self.withTLSServer(certificate: certificate, requests: requests) { app, endpoint in
            let keycloak = try KeycloakClient(application: app, config: Self.keycloak(endpoint: endpoint))
            let storage = try S3ObjectStorageProvider(application: app, config: Self.storage(endpoint: endpoint))
            let validator = try FHIRValidationClient(
                application: app, endpoint: endpoint + "/validate", identity: "sha256:" + String(repeating: "0", count: 64)
            )
            do {
                if certificate == "trusted" {
                    #expect(try await keycloak.fetchJWKS().keys.isEmpty)
                    #expect(try await keycloak.fetchGroups().isEmpty)
                    #expect(try await storage.download(key: "object", maximumBytes: 32) == Data("synthetic object".utf8))
                    await #expect(throws: (any Error).self) { try await storage.download(key: "redirect", maximumBytes: 32) }
                } else {
                    await #expect(throws: (any Error).self) { try await keycloak.fetchJWKS() }
                    await #expect(throws: (any Error).self) { try await keycloak.fetchGroups() }
                    await #expect(throws: (any Error).self) { try await storage.download(key: "object", maximumBytes: 32) }
                }
                // A trusted transport reaches validation, but cannot follow its redirect.
                await #expect(throws: (any Error).self) { try await validator.validate(Data("{}".utf8)) }
                #expect(requests.withLockedValue { $0 } == (certificate == "trusted" ? 6 : 0))
                try await storage.shutdown()
            } catch {
                try? await storage.shutdown()
                throw error
            }
            if certificate == "trusted" {
                // Storage owns its credentials, not the application's HTTP client.
                #expect(try await keycloak.fetchJWKS().keys.isEmpty)
            }
        }
    }
}


extension OutboundTransportTests {
    private static func keycloak(endpoint: String) -> KeycloakConfiguration {
        .init(
            issuer: TestApp.issuer,
            apiAudience: TestApp.apiAudience,
            url: endpoint,
            realm: "fixture",
            clientId: "fixture",
            clientSecret: "synthetic-secret",
            researcherRole: TestApp.researcherRole,
            participantRole: TestApp.participantRole
        )
    }

    private static func storage(endpoint: String) -> S3ObjectStorageConfiguration {
        .init(endpoint: endpoint, accessKeyId: "synthetic-key", secretAccessKey: "synthetic-secret", bucket: "fixture", region: "us-east-1")
    }

    private static func withTLSServer(
        certificate: String,
        requests: NIOLockedValueBox<Int>,
        test: @Sendable (Application, String) async throws -> Void
    ) async throws {
        let app = try await Application.make(.testing)
        let authorityFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: authorityFile) }
        do {
            let certificates = try TransportCertificates(
                hostname: certificate == "wrong-host" ? "wrong.example.test" : "localhost", expired: certificate == "expired"
            )
            try certificates.authority.write(to: authorityFile)
            try OutboundTransportConfiguration(
                environment: .production,
                certificateAuthorityFile: certificate == "unknown-ca" ? nil : authorityFile.path
            ).configure(app)
            app.http.server.configuration.tlsConfiguration = certificates.server
            registerRoutes(app, requests: requests)
            try await app.server.start(address: .hostname("127.0.0.1", port: 0))
            let port = try #require(app.http.server.shared.localAddress?.port)
            try await test(app, "https://127.0.0.1:\(port)")
            await app.server.shutdown()
            try await app.asyncShutdown()
        } catch {
            await app.server.shutdown()
            try? await app.asyncShutdown()
            throw error
        }
    }

    private static func registerRoutes(_ app: Application, requests: NIOLockedValueBox<Int>) {
        app.get("realms", "fixture", "protocol", "openid-connect", "certs") { _ in
            requests.withLockedValue { $0 += 1 }
            return Response(headers: ["Content-Type": "application/json"], body: .init(string: "{\"keys\":[]}"))
        }
        app.post("realms", "fixture", "protocol", "openid-connect", "token") { _ in
            requests.withLockedValue { $0 += 1 }
            return Response(headers: ["Content-Type": "application/json"], body: .init(string: "{\"access_token\":\"synthetic-token\"}"))
        }
        app.get("admin", "realms", "fixture", "groups") { _ in
            requests.withLockedValue { $0 += 1 }
            return Response(headers: ["Content-Type": "application/json"], body: .init(string: "[]"))
        }
        app.get("fixture", "object") { _ in
            requests.withLockedValue { $0 += 1 }
            return "synthetic object"
        }
        app.get("fixture", "redirect") { request in
            requests.withLockedValue { $0 += 1 }
            return request.redirect(to: "/redirect-target", redirectType: .temporary)
        }
        app.post("validate") { request in
            requests.withLockedValue { $0 += 1 }
            return request.redirect(to: "/redirect-target", redirectType: .temporary)
        }
        app.on(.GET, "redirect-target") { _ in
            Issue.record("Storage followed a redirect outside its configured endpoint")
            return "unexpected"
        }
        app.on(.POST, "redirect-target") { _ in
            Issue.record("Validation followed a redirect outside its configured endpoint")
            return "unexpected"
        }
    }
}
