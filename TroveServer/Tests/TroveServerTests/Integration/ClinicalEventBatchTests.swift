//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


/// Real persistence with a synthetic validation transport; not full-IG acceptance evidence.
struct ClinicalEventBatchTests {
    @Test
    func partialSuccessAndExactReplaySurviveReopening() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let bytes = try LocalPointEventFixture.bytes(source: fixture.source)
            let first = try Self.submission(bytes, fixture: fixture)
            let conflict = try Self.submission(bytes + Data(" ".utf8), fixture: fixture)
            let second = try Self.submission(LocalPointEventFixture.bytes(source: fixture.source, sequence: 2), fixture: fixture)
            let missingConsent = Components.Schemas.EventSubmission(eventBase64: second.eventBase64, targets: [
                .init(consentId: UUID().uuidString, outputFullUrls: second.targets[0].outputFullUrls)
            ])
            let submissions = [first, .init(eventBase64: "not-base64", targets: []), conflict, missingConsent, second]
            let outcomes = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let service = ClinicalEventService(database: app.db, validator: Self.validator())
                return try await service.acceptBatch(submissions, sourceID: fixture.source.id)
            }
            #expect(outcomes.count == 5)
            guard case .EventReceipt(let receipt) = outcomes[0], case .EventReceipt = outcomes[4] else {
                Issue.record("Independent valid members were not admitted")
                return
            }
            #expect(receipt.payloadSHA256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            #expect(outcomes[1].problemStatus == 400)
            #expect(outcomes[2].problemStatus == 409)
            #expect(outcomes[3].problemStatus == 404)
            try await ClinicalEventStoreTests.expectRows(events: 2, nodes: 2 * receipt.nodeCount, facts: 2, grants: 4, on: app.db)
            try await TestDatabase.withRestartedApplication(app) { reopened in
                try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                    let service = ClinicalEventService(database: reopened.db, validator: Self.validator())
                    let replay = try await service.acceptBatch(submissions, sourceID: fixture.source.id)
                    #expect(replay[0] == outcomes[0])
                    #expect(replay[4] == outcomes[4])
                    #expect(replay[1].problemStatus == 400)
                    #expect(replay[2].problemStatus == 409)
                    // The later valid member claimed this identity; the previously unaccepted intent now conflicts.
                    #expect(replay[3].problemStatus == 409)
                    try await ClinicalEventStoreTests.expectRows(events: 2, nodes: 2 * receipt.nodeCount, facts: 2, grants: 4, on: reopened.db)
                }
            }
        }
    }

    @Test
    func maximumBatchOfExactRetriesKeepsOneEvent() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let submission = try Self.submission(LocalPointEventFixture.bytes(source: fixture.source), fixture: fixture)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let results = try await ClinicalEventService(database: app.db, validator: Self.validator())
                    .acceptBatch(Array(repeating: submission, count: 16), sourceID: fixture.source.id)
                #expect(results.count == 16)
                guard case .EventReceipt(let receipt) = results[0] else {
                    Issue.record("Maximum supported batch was rejected")
                    return
                }
                #expect(Set(results).count == 1)
                try await ClinicalEventStoreTests.expectRows(events: 1, nodes: receipt.nodeCount, facts: 1, grants: 2, on: app.db)
            }
        }
    }

    @Test
    func cancellationPreservesCommittedPrefixAndStopsRemainingMembers() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let submissions = try (1...3).map { sequence in
                try Self.submission(LocalPointEventFixture.bytes(source: fixture.source, sequence: UInt64(sequence)), fixture: fixture)
            }
            let calls = ValidationCalls()
            let validator = FHIRValidationClient(expectedIdentity: Self.identity) { bytes in
                if await calls.next() == 2 { throw CancellationError() }
                return try Self.reply(bytes)
            }
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let service = ClinicalEventService(database: app.db, validator: validator)
                await #expect(throws: CancellationError.self) {
                    try await service.acceptBatch(submissions, sourceID: fixture.source.id)
                }
                #expect(await calls.invocations == 2)
                let recovered = try await ClinicalEventService(database: app.db, validator: Self.validator())
                    .accept(submission: submissions[0], sourceID: fixture.source.id)
                try await ClinicalEventStoreTests.expectRows(events: 1, nodes: recovered.nodeCount, facts: 1, grants: 2, on: app.db)
            }
        }
    }

    @Test(arguments: [0, 17])
    func invalidMemberCountFailsBeforeSourceLookup(count: Int) async throws {
        try await TestApp.withApp { app, _ in
            await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let service = ClinicalEventService(database: app.db, validator: Self.validator())
                await #expect {
                    try await service.acceptBatch(Array(repeating: .init(eventBase64: "e30=", targets: []), count: count), sourceID: UUID())
                } throws: { ($0 as? ServerError)?.status.code == 400 }
            }
        }
    }

    @Test
    func aggregateOverflowFailsBeforeSourceLookup() async throws {
        try await TestApp.withApp { app, _ in
            let encoded = Data(repeating: 32, count: 3 * 1024 * 1024).base64EncodedString()
            let member = Components.Schemas.EventSubmission(eventBase64: encoded, targets: [])
            await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                await #expect {
                    try await ClinicalEventService(database: app.db, validator: Self.validator()).acceptBatch([member, member], sourceID: UUID())
                } throws: { ($0 as? ServerError)?.status.code == 413 }
            }
        }
    }

    @Test
    func foreignSourceCannotReachValidation() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let foreign = AuthContext(
                issuer: TestApp.issuer,
                subject: "another-participant",
                email: "other@example.test",
                roles: [TestApp.participantRole],
                groups: [],
                researcherRole: TestApp.researcherRole,
                participantRole: TestApp.participantRole
            )
            let calls = ValidationCalls()
            let validator = FHIRValidationClient(expectedIdentity: Self.identity) { bytes in
                _ = await calls.next()
                return try Self.reply(bytes)
            }
            await AuthContext.$current.withValue(foreign) {
                await #expect {
                    try await ClinicalEventService(database: app.db, validator: validator)
                        .acceptBatch([.init(eventBase64: "e30=", targets: [])], sourceID: fixture.source.id)
                } throws: { ($0 as? ServerError)?.status.code == 404 }
            }
            #expect(await calls.invocations == 0)
        }
    }

    @Test
    func transportFailureIsSanitizedAndDoesNotDiscardLaterMembers() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let submission = try Self.submission(LocalPointEventFixture.bytes(source: fixture.source), fixture: fixture)
            let calls = ValidationCalls()
            let validator = FHIRValidationClient(expectedIdentity: Self.identity) { bytes in
                if await calls.next() == 1 { throw ServerError.internalServerError("private-payload-and-token") }
                return try Self.reply(bytes)
            }
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let outcomes = try await ClinicalEventService(database: app.db, validator: validator)
                    .acceptBatch([submission, submission], sourceID: fixture.source.id)
                #expect(outcomes[0].problemStatus == 503)
                guard case .EventReceipt = outcomes[1] else {
                    Issue.record("Later member was not admitted")
                    return
                }
                #expect(!String(decoding: try JSONEncoder().encode(outcomes), as: UTF8.self).contains("private-payload-and-token"))
            }
        }
    }
}


extension ClinicalEventBatchTests {
    private actor ValidationCalls {
        private(set) var invocations = 0
        func next() -> Int { invocations += 1; return invocations }
    }

    private static let identity = "sha256:" + String(repeating: "a", count: 64)

    static func validator() -> FHIRValidationClient {
        .init(expectedIdentity: identity, send: reply)
    }

    private static func reply(_ bytes: Data) throws -> (Int, Data) {
        (200, try JSONSerialization.data(withJSONObject: [
            "valid": true,
            "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            "contractRevision": FHIRValidationClient.contractRevision,
            "validatorIdentity": identity
        ]))
    }

    static func submission(_ bytes: Data, fixture: ClinicalEventStoreTests.Fixture) throws -> Components.Schemas.EventSubmission {
        let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "framing-test-only")
        return .init(eventBase64: bytes.base64EncodedString(), targets: fixture.targets(for: event).map {
            .init(consentId: $0.consentID.uuidString, outputFullUrls: $0.outputFullURLs)
        })
    }
}


extension Components.Schemas.EventBatchResult {
    var problemStatus: Int? {
        guard case .ProblemDetails(let problem) = self else {
            return nil
        }
        return problem.status
    }
}
