//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import OpenAPIRuntime
import TroveAPIClient


actor SourceRegistrationTransport: ClientTransport {
    enum Failure {
        case lostReply
        case malformedReply
    }

    private var binding: Components.Schemas.ParticipantSource
    private let status: Int
    private var failure: Failure?
    private var replyAction: (@Sendable () async throws -> Void)?
    private(set) var methods: [String] = []
    private(set) var paths: [String] = []
    private(set) var bodies: [Data] = []

    init(binding: Components.Schemas.ParticipantSource, status: Int = 200, failure: Failure? = nil) {
        self.binding = binding
        self.status = status
        self.failure = failure
    }

    func onReply(_ action: @escaping @Sendable () async throws -> Void) {
        replyAction = action
    }

    func replaceBinding(_ binding: Components.Schemas.ParticipantSource) {
        self.binding = binding
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        methods.append(request.method.rawValue)
        paths.append(request.path ?? "")
        if let body {
            bodies.append(try await Data(collecting: body, upTo: 16_384))
        } else {
            bodies.append(Data())
        }
        let action = replyAction
        replyAction = nil
        try await action?()
        if failure == .lostReply {
            failure = nil
            throw URLError(.networkConnectionLost)
        }
        if failure == .malformedReply {
            return (.init(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody("{}"))
        }
        if status != 200 {
            let body = "{\"title\":\"Sensitive upstream detail\",\"status\":\(status)}"
            return (.init(status: .init(code: status), headerFields: [.contentType: "application/problem+json"]), HTTPBody(body))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (.init(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(try encoder.encode(binding)))
    }
}
