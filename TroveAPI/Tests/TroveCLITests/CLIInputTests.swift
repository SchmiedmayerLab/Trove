//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import ArgumentParser
import Foundation
import Synchronization
import Testing


#if canImport(FoundationNetworking)
import FoundationNetworking


#endif
@testable import TroveCLI


struct CLIInputTests {
    @Test(arguments: [
        "http://research.example/api/v0", "https://user:password@research.example", "https://research.example?token=hidden",
        "https://research.example#fragment", "file:///tmp/api", "http://127.0.0.2/api/v0", "http://localhost/api/v0"
    ])
    func refusesUnsafeEndpoints(value: String) {
        #expect(throws: CLIError.invalidEndpoint) {
            try ConnectionOptions.endpoint(value, allowInsecureLoopback: true)
        }
    }

    @Test
    func requiresExplicitLoopbackOptIn() throws {
        #expect(throws: CLIError.invalidEndpoint) {
            try ConnectionOptions.endpoint("http://127.0.0.1:8080/api/v0", allowInsecureLoopback: false)
        }
        #expect(try ConnectionOptions.endpoint("http://127.0.0.1:8080/api/v0", allowInsecureLoopback: true).host == "127.0.0.1")
        #expect(try ConnectionOptions.endpoint("https://research.example/api/v0", allowInsecureLoopback: false).scheme == "https")
    }

    @Test(arguments: ["", "\n", "credential\r\nInjected: value", "credential with spaces", "é"])
    func rejectsMalformedCredentials(value: String) {
        #expect(throws: CLIError.invalidCredential) {
            try CredentialInput.token(from: Data(value.utf8))
        }
    }

    @Test
    func boundsCredentialSizeAndTrimsTrailingNewline() throws {
        #expect(throws: CLIError.invalidCredential) {
            try CredentialInput.token(from: Data(repeating: 65, count: 16_385))
        }
        #expect(try CredentialInput.token(from: Data("synthetic-test-credential\n".utf8)) == "synthetic-test-credential")
        #expect(throws: CLIError.invalidCredential) { try CredentialInput.read(file: nil, standardInput: false) }
        #expect(throws: CLIError.invalidCredential) { try CredentialInput.read(file: "/unused", standardInput: true) }
    }

    @Test
    func acceptsOnlyOwnerOnlyRegularCredentialFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trove-cli-credentials-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("credential")
        try Data("synthetic-test-credential".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try CredentialInput.read(file: file.path, standardInput: false) == "synthetic-test-credential")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        #expect(throws: CLIError.invalidCredential) { try CredentialInput.read(file: file.path, standardInput: false) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: CLIError.invalidCredential) { try CredentialInput.read(file: link.path, standardInput: false) }
        #expect(throws: CLIError.invalidCredential) { try CredentialInput.read(file: directory.path, standardInput: false) }
    }

    @Test
    func refusesEveryRedirect() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = try #require(URL(string: "https://research.example/api/v0"))
        let destination = try #require(URL(string: "https://other.example/capture"))
        let response = try #require(HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil))
        let refused = Mutex(false)
        RefuseRedirects().urlSession(
            session, task: session.dataTask(with: original), willPerformHTTPRedirection: response, newRequest: URLRequest(url: destination)
        ) { request in
            refused.withLock { $0 = request == nil }
        }
        #expect(refused.withLock { $0 })
    }

    @Test
    func publicationRequiresExplicitReceiptAndCannotAcceptDelegation() throws {
        let common = ["study", "publish", UUID().uuidString, "--server", "https://research.example", "--token-stdin"]
        #expect(throws: (any Error).self) { try TroveCommand.parseAsRoot(common) }
        let complete = common + ["--revision", UUID().uuidString, "--validation", UUID().uuidString]
        #expect(try TroveCommand.parseAsRoot(complete) is PublishStudy)
        #expect(throws: (any Error).self) {
            try TroveCommand.parseAsRoot(complete + ["--delegation", UUID().uuidString])
        }
    }

    @Test
    func draftEditRequiresRevisionAndTypedJSONFile() throws {
        let common = ["study", "edit", UUID().uuidString, "--server", "https://research.example", "--token-stdin", "--file", "edit.json"]
        #expect(throws: (any Error).self) { try TroveCommand.parseAsRoot(common) }
        let command = try #require(TroveCommand.parseAsRoot(common + ["--revision", UUID().uuidString]) as? EditStudy)
        #expect(command.file == "edit.json")
    }
}
