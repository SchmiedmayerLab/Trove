//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


struct ClinicalEventBatchHTTPTests {
    @Test(arguments: [
        (TestApp.Token.none, HTTPStatus.unauthorized), (.researcher(), .forbidden), (.participant(subject: "body-test"), .payloadTooLarge)
    ])
    func authenticationPrecedesEnvelopeCollection(identity: TestApp.Token, status: HTTPStatus) async throws {
        try await TestApp.withApp(token: identity) { app, token in
            try await app.test(.POST, "\(apiBasePath)/participant/sources/\(UUID())/events/batch", beforeRequest: {
                $0.bearerAuth(token)
                $0.headers.contentType = .json
                $0.body = .init(data: Data(repeating: 32, count: 6 * 1024 * 1024 + 1))
            }) { #expect($0.status == status) }
        }
    }

    @Test
    func malformedMembersReturnOrderedProblemsWithoutPayloadDisclosure() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await app.test(.POST, "\(apiBasePath)/participant/sources/\(fixture.source.id)/events/batch", beforeRequest: {
                $0.bearerAuth(token)
                try $0.encodeJSONBody(Components.Schemas.EventBatchSubmission(events: [
                    .init(eventBase64: "private-not-base64", targets: []), .init(eventBase64: "e30", targets: [])
                ]))
            }) { response in
                #expect(response.status == .ok)
                let results = try response.content.decode([Components.Schemas.EventBatchResult].self)
                #expect(results.map(\.problemStatus) == [400, 400])
                #expect(!response.body.string.contains("private-not-base64"))
            }
        }
    }

    @Test
    func revokedSourceFailsWholeBatch() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await app.test(.POST, "\(apiBasePath)/participant/sources/\(fixture.source.id)/revoke", beforeRequest: {
                $0.bearerAuth(token)
            }) { #expect($0.status == .ok) }
            try await app.test(.POST, "\(apiBasePath)/participant/sources/\(fixture.source.id)/events/batch", beforeRequest: {
                $0.bearerAuth(token)
                try $0.encodeJSONBody(Components.Schemas.EventBatchSubmission(events: [.init(eventBase64: "e30=", targets: [])]))
            }) { #expect($0.status == .conflict) }
        }
    }

    @Test(.enabled(if: Environment.get("TROVE_TEST_VALIDATOR_ASSETS") != nil, "Requires the isolated pinned full validator"))
    func fullValidatorAdmitsAndReplaysAroundARejectedMember() async throws {
        try #require(Environment.get("FHIR_VALIDATOR_URL") != nil && Environment.get("FHIR_VALIDATOR_IDENTITY") != nil)
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let submission = try ClinicalEventBatchTests.submission(ImmutablePointEventFixture.bytes(source: fixture.source), fixture: fixture)
            try await app.test(.POST, "\(apiBasePath)/participant/sources/\(fixture.source.id)/events/batch", beforeRequest: {
                $0.bearerAuth(token)
                try $0.encodeJSONBody(Components.Schemas.EventBatchSubmission(events: [
                    submission, .init(eventBase64: "invalid", targets: []), submission
                ]))
            }) { response in
                #expect(response.status == .ok)
                let results = try response.content.decode([Components.Schemas.EventBatchResult].self)
                try #require(results.count == 3)
                #expect(results[0] == results[2])
                #expect(results[1].problemStatus == 400)
                guard case .EventReceipt(let receipt) = results[0] else {
                    Issue.record("Full validator did not admit fixture")
                    return
                }
                try await ClinicalEventStoreTests.expectRows(events: 1, nodes: receipt.nodeCount, facts: 1, grants: 2, on: app.db)
            }
        }
    }
}
