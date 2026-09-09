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
import Testing
import VaporTesting


/// Runs generated-client requests through the real router and authentication middleware without a listening socket.
/// Only the response-loss fault is synthetic. Each instance belongs to one test application and signed test token.
actor ReceiverClientTransport: ClientTransport {
    private let application: Application
    private let token: String?
    private var loseBatchResponse: Bool
    private var loseRegistrationResponse: Bool
    private(set) var paths: [String] = []
    private(set) var batchBodies: [Data] = []
    private(set) var registrationBodies: [Data] = []

    init(application: Application, token: String?, loseBatchResponse: Bool = false, loseRegistrationResponse: Bool = false) {
        self.application = application
        self.token = token
        self.loseBatchResponse = loseBatchResponse
        self.loseRegistrationResponse = loseRegistrationResponse
    }

    func send(
        _ request: HTTPTypes.HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPTypes.HTTPResponse, HTTPBody?) {
        // ClientTransport receives the server base path separately, as URLSessionTransport does.
        let path = try baseURL.path + #require(request.path)
        let bytes: Data
        if let body {
            bytes = try await Data(collecting: body, upTo: 6 * 1024 * 1024)
        } else {
            bytes = Data()
        }
        var headers = HTTPHeaders()
        for field in request.headerFields { headers.add(name: field.name.rawName, value: field.value) }
        if let token { headers.bearerAuthorization = .init(token: token) }
        paths.append(path)
        if path.hasSuffix("/events/batch") { batchBodies.append(bytes) }
        let isRegistration = request.method == .post && path.hasSuffix("/participant/sources")
        if isRegistration { registrationBodies.append(bytes) }
        let response = try await application.performTest(request: .init(
            method: .init(rawValue: request.method.rawValue), url: .init(string: path), headers: headers, body: .init(data: bytes)
        ))
        if path.hasSuffix("/events/batch"), loseBatchResponse {
            loseBatchResponse = false
            // The router finished; committed transactions survive even though the client sees no response.
            throw URLError(.networkConnectionLost)
        }
        if isRegistration, loseRegistrationResponse {
            loseRegistrationResponse = false
            throw URLError(.networkConnectionLost)
        }
        var fields = HTTPFields()
        for header in response.headers {
            fields.append(.init(name: try #require(HTTPField.Name(header.name)), value: header.value))
        }
        return (
            HTTPTypes.HTTPResponse(status: .init(code: Int(response.status.code)), headerFields: fields),
            HTTPBody(Data(response.body.readableBytesView))
        )
    }
}
