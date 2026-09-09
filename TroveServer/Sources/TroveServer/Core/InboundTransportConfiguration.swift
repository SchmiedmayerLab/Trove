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


/// A serving process loads its identity once; certificate rotation requires restart.
struct InboundTransportConfiguration: Sendable {
    enum Failure: Error {
        case missingIdentity
        case invalidIdentity
    }

    let tls: TLSConfiguration?

    init(environment: AppEnvironment, certificateFile: String?, privateKeyFile: String?) throws {
        if environment == .development, certificateFile == nil, privateKeyFile == nil {
            tls = nil
            return
        }
        guard let certificateFile, let privateKeyFile else { throw Failure.missingIdentity }
        do {
            let certificates = try NIOSSLCertificate.fromPEMBytes(Self.readPEM(certificateFile))
            guard !certificates.isEmpty else { throw Failure.invalidIdentity }
            let key = try NIOSSLPrivateKey(bytes: Self.readPEM(privateKeyFile), format: .pem) { (_: NIOSSLPassphraseSetter<[UInt8]>) in
                // Daemons must never prompt on stdin for an encrypted key.
                throw Failure.invalidIdentity
            }
            var configuration = TLSConfiguration.makeServerConfiguration(
                certificateChain: certificates.map { .certificate($0) }, privateKey: .privateKey(key)
            )
            configuration.minimumTLSVersion = .tlsv12
            // Validate the identity before opening database or other service connections.
            _ = try NIOSSLContext(configuration: configuration)
            tls = configuration
        } catch {
            // Never include key material or filesystem details in startup diagnostics.
            throw Failure.invalidIdentity
        }
    }

    func configure(_ application: Application) {
        application.http.server.configuration.tlsConfiguration = tls
    }
}


extension InboundTransportConfiguration {
    private static func readPEM(_ path: String) throws -> [UInt8] {
        guard path.hasPrefix("/") else { throw Failure.invalidIdentity }
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        let maximumBytes = 1_048_576
        let bytes = try file.read(upToCount: maximumBytes + 1) ?? Data()
        guard !bytes.isEmpty, bytes.count <= maximumBytes else { throw Failure.invalidIdentity }
        return Array(bytes)
    }
}
