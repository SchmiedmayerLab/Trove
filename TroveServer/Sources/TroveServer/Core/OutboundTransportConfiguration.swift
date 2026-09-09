//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import NIOSSL
import Vapor


/// One trust policy for database connections and application-owned HTTP clients.
struct OutboundTransportConfiguration: Sendable {
    enum Failure: Error {
        case notConfigured
        case invalidCertificateAuthority
        case invalidEndpoint
    }

    fileprivate struct Key: StorageKey {
        typealias Value = OutboundTransportConfiguration
    }

    let environment: AppEnvironment
    let tls: TLSConfiguration

    init(environment: AppEnvironment, certificateAuthorityFile: String? = nil) throws {
        self.environment = environment
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.minimumTLSVersion = .tlsv12
        if let certificateAuthorityFile {
            do {
                guard certificateAuthorityFile.hasPrefix("/") else { throw Failure.invalidCertificateAuthority }
                let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: certificateAuthorityFile))
                defer { try? file.close() }
                let maximumBytes = 1_048_576
                let bytes = try file.read(upToCount: maximumBytes + 1) ?? Data()
                guard !bytes.isEmpty, bytes.count <= maximumBytes else { throw Failure.invalidCertificateAuthority }
                let certificates = try NIOSSLCertificate.fromPEMBytes(Array(bytes))
                guard !certificates.isEmpty else { throw Failure.invalidCertificateAuthority }
                // Retain public system roots; never disable certificate or hostname verification.
                tls.additionalTrustRoots = [.certificates(certificates)]
            } catch {
                throw Failure.invalidCertificateAuthority
            }
        }
        self.tls = tls
    }

    @discardableResult
    func validateEndpoint(_ endpoint: String) throws -> URL {
        guard !endpoint.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              let url = URL(string: endpoint), let host = url.host, !host.isEmpty,
              url.scheme == "https" || (environment == .development && url.scheme == "http"),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else {
            throw Failure.invalidEndpoint
        }
        return url
    }

    /// Install before accessing any HTTP client. Certificate changes require an application restart.
    func configure(_ application: Application) {
        application.http.client.configuration.tlsConfiguration = tls
        application.http.client.configuration.redirectConfiguration = .disallow
        application.storage[Key.self] = self
    }
}

extension Application {
    var outboundTransport: OutboundTransportConfiguration {
        get throws {
            guard let configuration = storage[OutboundTransportConfiguration.Key.self] else {
                throw OutboundTransportConfiguration.Failure.notConfigured
            }
            return configuration
        }
    }
}
