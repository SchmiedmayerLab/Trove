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


actor CollectionRefreshTransport: ClientTransport {
    let enrollments: [Components.Schemas.EnrollmentResponse]
    let plans: [Components.Schemas.ParticipantCollectionPlan]
    let failingRequest: Int?
    let beforeReply: (@Sendable (Int) async throws -> Void)?
    private(set) var paths: [String] = []

    init(
        enrollments: [Components.Schemas.EnrollmentResponse],
        plans: [Components.Schemas.ParticipantCollectionPlan],
        failingRequest: Int? = nil,
        beforeReply: (@Sendable (Int) async throws -> Void)? = nil
    ) {
        self.enrollments = enrollments
        self.plans = plans
        self.failingRequest = failingRequest
        self.beforeReply = beforeReply
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        guard request.method == .get, body == nil, let path = request.path else { throw URLError(.badURL) }
        paths.append(path)
        let requestNumber = paths.count
        try await beforeReply?(requestNumber)
        if requestNumber == failingRequest {
            throw URLError(.networkConnectionLost)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bytes: Data
        if path == "/participant/enrollments" {
            bytes = try encoder.encode(enrollments)
        } else {
            guard let plan = plans.first(where: { path == "/participant/enrollments/\($0.enrollmentId)/collection-plan" }) else {
                throw URLError(.resourceUnavailable)
            }
            bytes = try encoder.encode(plan)
        }
        return (.init(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(bytes))
    }
}
