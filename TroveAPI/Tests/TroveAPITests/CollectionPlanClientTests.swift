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
import TroveAPIClient


struct CollectionPlanClientTests {
    private struct Transport: ClientTransport {
        func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
            #expect(request.method == .get && body == nil)
            #expect(operationID == "getParticipantCollectionPlan")
            let json = """
                {"enrollmentId":"00000000-0000-4000-8000-000000000001","stateVersion":2,
                 "asOf":"2001-01-01T00:00:01.654321Z","windows":[{
                 "consentId":"00000000-0000-4000-8000-000000000002",
                 "publicationId":"00000000-0000-4000-8000-000000000003","revision":1,
                 "start":"2001-01-01T00:00:00.123456Z","end":"2001-01-01T00:00:00.654321Z","requirements":[]}]}
                """
            return (.init(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(json))
        }
    }

    @Test
    func generatedClientPreservesBothWindowBoundaries() async throws {
        let client = Client(serverURL: try #require(URL(string: "https://trove.test")), configuration: .trove, transport: Transport())
        let response = try await client.getParticipantCollectionPlan(
            .init(path: .init(enrollmentId: "00000000-0000-4000-8000-000000000001"))
        )
        let plan = try response.ok.body.json
        let window = try #require(plan.windows.first)
        #expect(window.start == Date(timeIntervalSinceReferenceDate: 0.123456))
        #expect(window.end == Date(timeIntervalSinceReferenceDate: 0.654321))
        #expect(plan.asOf == Date(timeIntervalSinceReferenceDate: 1.654321))
    }
}
