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


struct EventBatchClientTests {
    private struct Transport: ClientTransport {
        let submissions: [Components.Schemas.EventSubmission]
        let outcomes: [Components.Schemas.EventBatchResult]

        func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
            #expect(request.method == .post)
            #expect(operationID == "submitParticipantEventBatch")
            #expect(request.path?.hasSuffix("/events/batch") == true)
            let body = try #require(body)
            let bytes = try await Data(collecting: body, upTo: 1024 * 1024)
            let requestEncoder = JSONEncoder()
            requestEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            #expect(bytes == (try requestEncoder.encode(Components.Schemas.EventBatchSubmission(events: submissions))))
            let decoded = try JSONDecoder().decode(Components.Schemas.EventBatchSubmission.self, from: bytes)
            #expect(decoded.events == submissions)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return (.init(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(try encoder.encode(outcomes)))
        }
    }

    @Test
    func generatedClientPreservesBytesIntentAndMixedOutcomes() async throws {
        let payload = DeliveryFixture.payload(sequence: 1, changes: ["sample"])
        let original = payload.bytes + Data("\n  ".utf8)
        let commitment = try EventSubmissionCommitment(sourceID: DeliveryFixture.sourceID, originalBytes: original, targets: payload.targets)
        let receipt = Components.Schemas.EventReceipt(
            eventId: UUID().uuidString,
            sourceId: DeliveryFixture.sourceID.uuidString.lowercased(),
            producerEventIdentifier: commitment.producerEventIdentifier,
            payloadSHA256: commitment.payloadSHA256,
            targetIntentSHA256: commitment.targetIntent.sha256,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            nodeCount: commitment.nodeCount
        )
        let submitted = Components.Schemas.EventSubmission(eventBase64: original.base64EncodedString(), targets: [
            .init(consentId: DeliveryFixture.consentID.uuidString, outputFullUrls: ["urn:output:a"])
        ])
        let submissions = [submitted, Components.Schemas.EventSubmission(eventBase64: "invalid", targets: [])]
        let outcomes: [Components.Schemas.EventBatchResult] = [
            .EventReceipt(receipt), .ProblemDetails(.init(title: "Event Rejected", status: 400, detail: "The event could not be admitted"))
        ]
        let client = Client(
            serverURL: try #require(URL(string: "https://trove.test")),
            configuration: .trove,
            transport: Transport(submissions: submissions, outcomes: outcomes)
        )
        let response = try await client.submitParticipantEventBatch(.init(
            path: .init(sourceId: DeliveryFixture.sourceID.uuidString), body: .json(.init(events: submissions))
        ))
        #expect(try response.ok.body.json == outcomes)
    }
}
