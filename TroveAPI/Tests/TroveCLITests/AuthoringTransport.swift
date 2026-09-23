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


actor AuthoringTransport: ClientTransport {
    struct Record: Sendable {
        let request: HTTPRequest
        let body: Data
        let operation: String
    }

    private let status: Int
    private let response: Data
    private(set) var records: [Record] = []

    init<Value: Encodable>(response: Value, status: Int = 200) throws {
        self.status = status
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.response = try encoder.encode(response)
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        let data: Data
        if let body {
            data = try await Data(collecting: body, upTo: 1_048_576)
        } else {
            data = Data()
        }
        records.append(.init(request: request, body: data, operation: operationID))
        return (.init(status: .init(code: status), headerFields: [.contentType: "application/json"]), HTTPBody(response))
    }
}
