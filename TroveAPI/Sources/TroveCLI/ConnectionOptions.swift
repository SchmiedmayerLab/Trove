//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import ArgumentParser
import AsyncHTTPClient
import Foundation
import OpenAPIAsyncHTTPClient
import OpenAPIURLSession


#if canImport(FoundationNetworking)
import FoundationNetworking


#endif


struct DraftAccessOptions: ParsableArguments {
    @Option(help: "Grant ID for a registered draft-only client; omit for interactive authority.", transform: CLIInput.uuid) var delegation: UUID?
}


/// Refuse redirects, including same-origin redirects, before another request can carry a credential.
final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}


struct ConnectionOptions: ParsableArguments {
    @Option(help: "API base URL, including its version path, for example https://research.example/api/v0.") var server: String
    @Option(help: "Owner-only regular file containing the bearer token. Tokens are never accepted as argument values.") var tokenFile: String?
    @Flag(help: "Read the bearer token from piped standard input; interactive terminals are refused.") var tokenStdin = false
    @Flag(help: "Allow HTTP only for a numeric loopback address during local development.") var allowInsecureLoopback = false

    static func endpoint(_ value: String, allowInsecureLoopback: Bool) throws -> URL {
        guard let components = URLComponents(string: value),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url else {
            throw CLIError.invalidEndpoint
        }
        let secure = components.scheme?.lowercased() == "https"
        let loopback = ["127.0.0.1", "::1", "[::1]"].contains(host)
        guard secure || (allowInsecureLoopback && components.scheme == "http" && loopback) else {
            throw CLIError.invalidEndpoint
        }
        return url
    }

    /// Keep the streaming transport alive until the complete response has been consumed.
    func withRecordingClient(_ operation: (AuthoringClient) async throws -> Void) async throws {
        let endpoint = try Self.endpoint(server, allowInsecureLoopback: allowInsecureLoopback)
        let token = try CredentialInput.read(file: tokenFile, standardInput: tokenStdin)
        let http = HTTPClient(configuration: .init(
            redirectConfiguration: .disallow,
            timeout: .init(connect: .seconds(30), read: .seconds(60))
        ))
        do {
            let client = AuthoringClient(
                serverURL: endpoint,
                token: token,
                transport: AsyncHTTPClientTransport(configuration: .init(client: http, timeout: .minutes(10)))
            )
            try await operation(client)
        } catch {
            try? await http.shutdown()
            throw CLIError.sanitized(error)
        }
        // The output is already complete; a shutdown failure must not suggest downloading again.
        try? await http.shutdown()
    }

    func client() throws -> AuthoringClient {
        let endpoint = try Self.endpoint(server, allowInsecureLoopback: allowInsecureLoopback)
        let token = try CredentialInput.read(file: tokenFile, standardInput: tokenStdin)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
        return AuthoringClient(
            serverURL: endpoint,
            token: token,
            transport: URLSessionTransport(configuration: .init(session: session))
        )
    }
}
