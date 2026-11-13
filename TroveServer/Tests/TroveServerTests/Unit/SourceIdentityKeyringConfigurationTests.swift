//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import Testing
@testable import TroveServer


struct SourceIdentityKeyringConfigurationTests {
    @Test
    func configurationHasNoImplicitCurrentKeyOrDuplicateKeyIdentifiers() throws {
        let entry = Self.entry()
        let valid = try Self.configuration(entries: [entry])
        #expect(try SourceIdentityKeyring(configuration: valid).currentKeyID == "current")
        let invalid = try [
            Self.configuration(entries: []), Self.configuration(entries: [entry, entry]),
            Self.configuration(entries: [entry], current: "missing"),
            Self.configuration(entries: [entry], version: 2),
            Self.configuration(entries: (0..<9).map { Self.entry(id: "key-\($0)") }, current: "key-0"),
            Self.configuration(entries: [Self.entry(id: "current key")], current: "current key"),
            Self.configuration(entries: [Self.entry(id: String(repeating: "x", count: 65))], current: String(repeating: "x", count: 65)),
            Self.configuration(entries: [["id": "current", "keyBase64": Data(repeating: 0, count: 31).base64EncodedString()]]),
            Self.configuration(entries: [["id": "current", "keyBase64": "invalid"]]),
            Data("{\"secret\":\"must-not-appear-in-errors\"".utf8), Data(repeating: 32, count: 16_385)
        ]
        for bytes in invalid {
            #expect(throws: SourceIdentityKeyring.Failure.invalidConfiguration) { try SourceIdentityKeyring(configuration: bytes) }
        }
    }

    @Test
    func secretFileRequiresRestrictedRegularFileAndSupportsMountedSecretSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = directory.appendingPathComponent("keyring.json")
        try Self.configuration(entries: [Self.entry()]).write(to: secret)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: secret.path)
        #expect(try SourceIdentityKeyring.load(file: secret.path).currentKeyID == "current")
        let link = directory.appendingPathComponent("mounted-secret")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        #expect(try SourceIdentityKeyring.load(file: link.path).currentKeyID == "current")
        try FileManager.default.setAttributes([.posixPermissions: 0o440], ofItemAtPath: secret.path)
        #expect(try SourceIdentityKeyring.load(file: secret.path).currentKeyID == "current")
        for mode in [0o444, 0o460, 0o470] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: secret.path)
            #expect(throws: SourceIdentityKeyring.Failure.invalidConfiguration) { try SourceIdentityKeyring.load(file: secret.path) }
        }
        for path in [directory.path, directory.appendingPathComponent("missing").path, "relative.json", secret.path + "\0ignored"] {
            #expect(throws: SourceIdentityKeyring.Failure.invalidConfiguration) { try SourceIdentityKeyring.load(file: path) }
        }
    }

    @Test
    func emptyMalformedAndOversizedSecretFilesFailWithoutLeakingTheirContents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = directory.appendingPathComponent("keyring.json")
        for bytes in [Data(), Data("sensitive-config-value".utf8), Data(repeating: 32, count: 16_385)] {
            try bytes.write(to: secret)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
            #expect(throws: SourceIdentityKeyring.Failure.invalidConfiguration) { try SourceIdentityKeyring.load(file: secret.path) }
        }
    }
}


extension SourceIdentityKeyringConfigurationTests {
    private static func entry(id: String = "current") -> [String: String] {
        ["id": id, "keyBase64": SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }]
    }

    private static func configuration(entries: [[String: String]], current: String = "current", version: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": version, "currentKeyID": current, "keys": entries])
    }
}
