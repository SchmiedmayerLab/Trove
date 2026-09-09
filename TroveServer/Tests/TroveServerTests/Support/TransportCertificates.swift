//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import NIOSSL
import X509


/// Fresh, short-lived certificates exercise system trust without expiring repository fixtures.
struct TransportCertificates {
    let authority: Data
    let certificate: Data
    let privateKey: Data
    let server: TLSConfiguration

    init(hostname: String = "localhost", expired: Bool = false) throws {
        let now = Date()
        let authorityKey = P256.Signing.PrivateKey()
        let serverKey = P256.Signing.PrivateKey()
        let name = try DistinguishedName { CommonName("Trove Synthetic Test CA") }
        let authority = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: .init(authorityKey.publicKey),
            notValidBefore: now.addingTimeInterval(-86400 * 365),
            notValidAfter: now.addingTimeInterval(86400 * 365),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true))
            },
            issuerPrivateKey: .init(authorityKey)
        )
        let leaf = try Self.leaf(
            hostname: hostname,
            expiration: expired ? now.addingTimeInterval(-86400) : now.addingTimeInterval(86400),
            issuer: (name, authorityKey),
            key: serverKey
        )
        self.authority = Data(try authority.serializeAsPEM().pemString.utf8)
        self.certificate = Data(try leaf.serializeAsPEM().pemString.utf8)
        self.privateKey = Data(serverKey.pemRepresentation.utf8)
        self.server = try .makeServerConfiguration(
            certificateChain: NIOSSLCertificate.fromPEMBytes(Array(leaf.serializeAsPEM().pemString.utf8)).map { .certificate($0) },
            privateKey: .privateKey(.init(bytes: Array(serverKey.pemRepresentation.utf8), format: .pem))
        )
    }
}


extension TransportCertificates {
    private static func leaf(
        hostname: String,
        expiration: Date,
        issuer: (DistinguishedName, P256.Signing.PrivateKey),
        key: P256.Signing.PrivateKey
    ) throws -> Certificate {
        try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: .init(key.publicKey),
            notValidBefore: expiration.addingTimeInterval(-86400 * 2),
            notValidAfter: expiration,
            issuer: issuer.0,
            subject: DistinguishedName { CommonName(hostname) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames(hostname == "localhost"
                    ? [.dnsName(hostname), .ipAddress(.init(contentBytes: [127, 0, 0, 1]))]
                    : [.dnsName(hostname)])
            },
            issuerPrivateKey: .init(issuer.1)
        )
    }
}
