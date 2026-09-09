//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import SQLKit
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


/// Admission is seeded through the real store with a synthetic validated projection.
/// These tests exercise authenticated receipt recovery, not FHIR validation.
struct ClinicalEventReceiptHTTPTests {
    private typealias Body = Components.Schemas.EventReceiptLookup

    private struct Fixture: Sendable {
        let domain: ClinicalEventStoreTests.Fixture
        let receipt: ClinicalEventReceipt
        var body: Body
    }

    enum Mutation: Sendable {
        case digest, intent, missingEvent, namespace, malformedEvent, uppercaseDigest, duplicateIntent, excessiveIntent
    }

    @Test
    func receiptSurvivesWithdrawalAndSourceRevocationWithoutRestoringAccess() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await Self.prepare(on: app)
            let first = try await Self.recover(fixture, on: app, token: token)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: fixture.domain.enrollmentIDs[0])
                _ = try await SourceBindingService(database: app.db).revoke(id: fixture.domain.source.id)
            }
            var reversed = fixture
            reversed.body.targets.reverse()
            let recovered = try await Self.recover(reversed, on: app, token: token)
            #expect(recovered == first)
            #expect(recovered.eventId == fixture.receipt.eventID.uuidString.lowercased())
            #expect(recovered.payloadSHA256 == fixture.receipt.payloadSHA256)
            try await ClinicalEventStoreTests.expectRows(events: 1, nodes: 2, facts: 1, grants: 2, on: app.db)
            let store = ClinicalEventStore(database: app.db)
            #expect(try await store.effectiveGrantCount(studyID: fixture.domain.studyIDs[0]) == 0)
            #expect(try await store.effectiveGrantCount(studyID: fixture.domain.studyIDs[1]) == 1)
            let sql = try #require(app.db as? any SQLDatabase)
            let rows = try await sql.raw("SELECT * FROM audit_events WHERE action = 'clinical.event.receipt.disclosure'").all()
            #expect(rows.count == 2)
            for row in rows {
                #expect(try row.decode(column: "outcome", as: String.self) == "disclosure_intent")
                #expect(try row.decode(column: "participant_id", as: UUID.self) == fixture.domain.source.participantID)
                #expect(try row.decode(column: "source_binding_id", as: UUID.self) == fixture.domain.source.id)
                #expect(try row.decode(column: "target_id", as: UUID.self) == fixture.receipt.eventID)
                #expect(try row.decode(column: "study_id", as: UUID?.self) == nil)
            }
            // Receipt recovery must not reopen the revoked upload path.
            try await app.test(.POST, "\(apiBasePath)/participant/sources/\(fixture.domain.source.id)/events", beforeRequest: {
                $0.bearerAuth(token)
                try $0.encodeJSONBody(Components.Schemas.EventSubmission(
                    eventBase64: Data("must not reach validation".utf8).base64EncodedString(), targets: fixture.body.targets
                ))
            }) { response in
                #expect(response.status == .conflict)
            }
        }
    }

    @Test(arguments: [
        (TestApp.Token.none, HTTPStatus.unauthorized),
        (.researcher(), .forbidden),
        (.participant(subject: "foreign-participant"), .notFound)
    ])
    func nonownersCannotRecoverReceipts(identity: TestApp.Token, status: HTTPStatus) async throws {
        try await TestApp.withApp(token: identity) { app, token in
            let fixture = try await Self.prepare(on: app)
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: "foreign-participant")
            try await Self.expectDenied(fixture, status: status, on: app, token: token)
        }
    }

    @Test(arguments: [
        (Mutation.digest, HTTPStatus.conflict), (.intent, .conflict), (.missingEvent, .notFound),
        (.namespace, .badRequest), (.malformedEvent, .badRequest), (.uppercaseDigest, .badRequest),
        (.duplicateIntent, .badRequest), (.excessiveIntent, .badRequest)
    ])
    func lookupRequiresTheOriginalIdentityDigestAndIntent(mutation: Mutation, status: HTTPStatus) async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            var fixture = try await Self.prepare(on: app)
            switch mutation {
            case .digest: fixture.body.payloadSHA256 = String(repeating: "0", count: 64)
            case .intent: fixture.body.targets.removeLast()
            case .missingEvent: fixture.body.producerEventIdentifier.value = "e0:\(fixture.domain.source.id.uuidString.lowercased()):999"
            case .namespace: fixture.body.producerEventIdentifier.system = "not a URI"
            case .malformedEvent: fixture.body.producerEventIdentifier.value = "e0:invalid:1"
            case .uppercaseDigest: fixture.body.payloadSHA256 = String(repeating: "A", count: 64)
            case .duplicateIntent: fixture.body.targets.append(fixture.body.targets[0])
            case .excessiveIntent:
                fixture.body.targets = (0..<17).map { _ in .init(consentId: UUID().uuidString, outputFullUrls: ["urn:uuid:point"]) }
            }
            try await Self.expectDenied(fixture, status: status, on: app, token: token)
        }
    }

    @Test
    func anotherOwnedStreamCannotRecoverTheReceipt() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await Self.prepare(on: app)
            let other = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await SourceBindingService(database: app.db).register(registrationID: UUID())
            }
            try await app.test(.POST, Self.path(other.id), beforeRequest: {
                $0.bearerAuth(token)
                try $0.encodeJSONBody(fixture.body)
            }) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test
    func unavailableAuditStorageReleasesNoReceipt() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await Self.prepare(on: app)
            try await app.db.schema("audit_events").delete()
            try await app.test(.POST, Self.path(fixture.domain.source.id), beforeRequest: {
                $0.bearerAuth(token)
                try $0.encodeJSONBody(fixture.body)
            }) { response in
                #expect(response.status == .internalServerError)
                #expect(!response.body.string.contains(fixture.receipt.payloadSHA256))
                #expect(!response.body.string.contains(fixture.receipt.eventID.uuidString.lowercased()))
            }
            try await ClinicalEventStoreTests.expectRows(events: 1, nodes: 2, facts: 1, grants: 2, on: app.db)
        }
    }

    @Test(arguments: [
        ("{", HTTPStatus.badRequest),
        (String(repeating: " ", count: 1024 * 1024 + 1), HTTPStatus.payloadTooLarge)
    ])
    func malformedOrOversizedBodiesAreRejected(body: String, status: HTTPStatus) async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            try await app.test(.POST, Self.path(UUID()), beforeRequest: {
                $0.bearerAuth(token)
                $0.headers.contentType = .json
                $0.body = .init(string: body)
            }) { response in
                #expect(response.status == status)
            }
        }
    }
}


extension ClinicalEventReceiptHTTPTests {
    private static func path(_ sourceID: UUID) -> String {
        "\(apiBasePath)/participant/sources/\(sourceID)/event-receipts/lookup"
    }

    private static func prepare(on app: Application) async throws -> Fixture {
        let domain = try await ClinicalEventStoreTests.prepare(on: app)
        let receipt = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            try await ClinicalEventStore(database: app.db).accept(
                ClinicalEventStoreTests.event(source: domain.source), sourceID: domain.source.id, targets: domain.targets
            )
        }
        return .init(domain: domain, receipt: receipt, body: .init(
            producerEventIdentifier: .init(system: receipt.producerEventIdentifier.system, value: receipt.producerEventIdentifier.value),
            payloadSHA256: receipt.payloadSHA256,
            targets: domain.targets.map { .init(consentId: $0.consentID.uuidString, outputFullUrls: $0.outputFullURLs) }
        ))
    }

    private static func recover(_ fixture: Fixture, on app: Application, token: String?) async throws -> Components.Schemas.EventReceipt {
        var receipt: Components.Schemas.EventReceipt?
        try await app.test(.POST, path(fixture.domain.source.id), beforeRequest: {
            $0.bearerAuth(token)
            try $0.encodeJSONBody(fixture.body)
        }) { response in
            try #require(response.status == .ok)
            let object = try #require(try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
            #expect(Set(object.keys) == [
                "eventId", "sourceId", "producerEventIdentifier", "payloadSHA256", "targetIntentSHA256", "receivedAt", "nodeCount"
            ])
            receipt = try response.content.decode(Components.Schemas.EventReceipt.self)
        }
        return try #require(receipt)
    }

    private static func expectDenied(_ fixture: Fixture, status: HTTPStatus, on app: Application, token: String?) async throws {
        try await app.test(.POST, path(fixture.domain.source.id), beforeRequest: {
            $0.bearerAuth(token)
            try $0.encodeJSONBody(fixture.body)
        }) { response in
            #expect(response.status == status)
            #expect(!response.body.string.contains(fixture.receipt.payloadSHA256))
        }
        try await ClinicalEventStoreTests.expectRows(events: 1, nodes: 2, facts: 1, grants: 2, on: app.db)
        let sql = try #require(app.db as? any SQLDatabase)
        let row = try #require(try await sql.raw("""
            SELECT COUNT(*) AS count FROM audit_events WHERE action = 'clinical.event.receipt.disclosure'
            """)
            .first())
        #expect(try row.decode(column: "count", as: Int.self) == 0)
    }
}
