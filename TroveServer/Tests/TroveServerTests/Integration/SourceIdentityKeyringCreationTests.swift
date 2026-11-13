//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import GroveFHIRContract
import Testing
@testable import TroveServer
import Vapor


struct SourceIdentityKeyringCreationTests {
    @Test
    func commandCreatesARestrictedRecoverableKeyringWithoutConfiguringServices() async throws {
        try await Self.withDirectory { directory in
            let path = directory.appendingPathComponent("keyring.secret").path
            let environment = Environment(name: "production", arguments: ["TroveServer", "create-source-keyring", "--output", path])
            #expect(!environment.isServing && !environment.isDatabaseMigration)
            let app = try await Application.make(environment)
            do {
                try await configure(app)
                try await app.execute()
                try await app.asyncShutdown()
            } catch {
                try? await app.asyncShutdown()
                throw error
            }
            let keyring = try SourceIdentityKeyring.load(file: path)
            let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
            #expect(permissions == 0o600)
            let sourceID = UUID(), participantID = UUID()
            let context = try SourceIdentityKeyContext(
                owner: (participantID: participantID, sourceID: sourceID),
                keyID: UUID(),
                epoch: KeyEpoch(1),
                identifierRoot: "https://fixture.test/sources",
                repository: BusinessIdentifier(system: IdentifierSystem("https://fixture.test/repository"), value: "healthkit")
            )
            let key = SymmetricKey(size: .bits256)
            let envelope = try keyring.seal(key, context: context)
            let reopened = try SourceIdentityKeyring.load(file: path)
            #expect(try reopened.open(envelope, context: context) == key)
        }
    }

    @Test(arguments: ["empty", "corrupt", "valid", "symlink"])
    func existingDestinationsAreNeverReplaced(kind: String) async throws {
        try await Self.withDirectory { directory in
            let url = directory.appendingPathComponent("keyring.secret")
            switch kind {
            case "valid": try SourceIdentityKeyring.create(file: url.path)
            case "symlink":
                let target = directory.appendingPathComponent("target.secret")
                try Data("synthetic retained bytes".utf8).write(to: target)
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            default: try (kind == "empty" ? Data() : Data("synthetic corrupt file".utf8)).write(to: url)
            }
            let original = try Data(contentsOf: url)
            #expect(throws: SourceIdentityKeyring.Failure.creationRefused) { try SourceIdentityKeyring.create(file: url.path) }
            #expect(try Data(contentsOf: url) == original)
            if kind == "symlink" {
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).hasSuffix("target.secret"))
            }
        }
    }

    @Test
    func concurrentInitializationCreatesExactlyOneKeyring() async throws {
        try await Self.withDirectory { directory in
            let path = directory.appendingPathComponent("keyring.secret").path
            async let first = Self.create(path)
            async let second = Self.create(path)
            let results = try await [first, second]
            #expect(results.filter { $0 }.count == 1)
            _ = try SourceIdentityKeyring.load(file: path)
        }
    }

    @Test(arguments: ["relative.secret", "/nonexistent-trove-fixture-parent/keyring.secret", "/invalid\0path"])
    func invalidDestinationsFailExplicitly(path: String) {
        #expect(throws: SourceIdentityKeyring.Failure.creationRefused) { try SourceIdentityKeyring.create(file: path) }
    }
}


extension SourceIdentityKeyringCreationTests {
    private static func create(_ path: String) async throws -> Bool {
        do {
            try SourceIdentityKeyring.create(file: path)
            return true
        } catch SourceIdentityKeyring.Failure.creationRefused {
            return false
        }
    }

    private static func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-keyring-creation-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}
