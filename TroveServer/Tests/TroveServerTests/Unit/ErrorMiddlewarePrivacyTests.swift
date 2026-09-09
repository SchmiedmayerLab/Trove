//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Logging
import OpenAPIRuntime
import Synchronization
import Testing
@testable import TroveServer


struct ErrorMiddlewarePrivacyTests {
    private struct SensitiveError: Error {
        let privateValue: String
    }

    private struct SensitiveResponseError: Error, HTTPResponseConvertible {
        let privateValue: String
        let httpStatus: HTTPResponse.Status
        var httpHeaderFields: HTTPFields { [.authorization: privateValue] }
        var httpBody: HTTPBody? { HTTPBody(privateValue) }
    }

    private final class LogCapture: Sendable {
        let entries = Mutex<[String]>([])
    }

    private struct CapturingLogHandler: LogHandler {
        let capture: LogCapture
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace

        func log(event: LogEvent) {
            let entry = "\(event.message) \(metadata) \(event.metadata ?? [:])"
            capture.entries.withLock { $0.append(entry) }
        }

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }
    }

    @Test(arguments: ["decoding", "unexpected", "wrapped", "server", "convertible", "convertible-server"])
    func sensitiveErrorValuesAreAbsentFromLogsAndResponses(kind: String) async throws {
        let sentinel = "private-consent-answer-and-token-DO-NOT-LOG"
        let capture = LogCapture()
        let logger = Logger(label: "privacy-test") { _ in CapturingLogHandler(capture: capture) }
        let middleware = ErrorMiddleware(logger: logger)
        let request = HTTPRequest(method: .post, scheme: "https", authority: "example.test", path: "/consents")
        let metadata = ServerRequestMetadata()
        let error: any Error = switch kind {
        case "decoding":
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: sentinel))
        case "server":
            TroveServer.ServerError.internalServerError(sentinel)
        case "convertible", "convertible-server":
            SensitiveResponseError(privateValue: sentinel, httpStatus: kind == "convertible" ? .badRequest : .internalServerError)
        case "wrapped":
            OpenAPIRuntime.ServerError(
                operationID: "submitConsent",
                request: request,
                requestBody: nil,
                requestMetadata: metadata,
                causeDescription: sentinel,
                underlyingError: SensitiveError(privateValue: sentinel)
            )
        default:
            SensitiveError(privateValue: sentinel)
        }
        let (response, body) = try await middleware.intercept(
            request, body: nil, metadata: metadata, operationID: "submitConsent"
        ) { _, _, _ in throw error }
        let responseBody = try await String(collecting: #require(body), upTo: 4096)
        let entries = capture.entries.withLock { $0 }
        #expect(response.status == (["decoding", "convertible"].contains(kind) ? .badRequest : .internalServerError))
        #expect(response.headerFields[.authorization] == nil)
        #expect(!responseBody.contains(sentinel))
        #expect(entries.count == 1)
        #expect(entries.allSatisfy { !$0.contains(sentinel) })
        #expect(entries.allSatisfy { $0.contains("submitConsent") && $0.contains("errorType") })
    }
}
