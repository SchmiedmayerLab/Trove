//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SQLKit
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


/// Synthetic admitted projection, real HTTP authorization and transactional grant commands.
struct ClinicalAttributionHTTPTests {
    @Test
    func commandSurvivesDatabaseReopeningAndWithdrawalWithoutRestoringAccess() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let event = try await Self.seed(fixture, on: app)
            let body = Components.Schemas.EventAttribution(
                commandId: UUID().uuidString,
                targets: [.init(consentId: fixture.consentIDs[1].uuidString, outputFullUrls: ["urn:uuid:point"])]
            )
            let first = try await Self.send(body, path: Self.path(fixture, event: event), token: token, on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: fixture.enrollmentIDs[1])
            }
            try await TestDatabase.withRestartedApplication(app) { reopened in
                try await configureServices(
                    for: reopened, storageProvider: InMemoryObjectStorageProvider(), validator: FHIRValidationClient(application: reopened)
                )
                _ = try await TestApp.configureTransport(for: reopened)
                let retry = try await Self.send(body, path: Self.path(fixture, event: event), token: token, on: reopened)
                #expect(retry == first)
                #expect(retry.authorizedOutputCount == 1)
                let store = ClinicalEventStore(database: reopened.db)
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 1)
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[1]) == 0)
                try await ClinicalEventStoreTests.expectRows(events: 1, nodes: 2, facts: 1, grants: 2, on: reopened.db)
            }
        }
    }

    @Test(arguments: [
        (TestApp.Token.none, HTTPStatus.unauthorized),
        (.researcher(), .forbidden),
        (.participant(subject: "other-participant"), .notFound)
    ])
    func onlyTheSourceOwnerCanAttribute(identity: TestApp.Token, status: HTTPStatus) async throws {
        try await TestApp.withApp(token: identity) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let event = try await Self.seed(fixture, on: app)
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: "other-participant")
            try await app.test(.POST, Self.path(fixture, event: event), beforeRequest: {
                $0.bearerAuth(token)
                try $0.encodeJSONBody(Components.Schemas.EventAttribution(
                    commandId: UUID().uuidString,
                    targets: [.init(consentId: fixture.consentIDs[1].uuidString, outputFullUrls: ["urn:uuid:point"])]
                ))
            }) { response in
                #expect(response.status == status)
                #expect(!response.body.string.contains(event.payloadSHA256))
            }
            try await ClinicalEventStoreTests.expectRows(events: 1, nodes: 2, facts: 1, grants: 1, on: app.db)
        }
    }

    @Test(arguments: ["urn:uuid:patient", "urn:uuid:absent"])
    func invalidOutputCannotPartiallyGrantOtherTargets(output: String) async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let event = try await Self.seed(fixture, on: app)
            try await app.test(.POST, Self.path(fixture, event: event), beforeRequest: {
                $0.bearerAuth(token)
                try $0.encodeJSONBody(Components.Schemas.EventAttribution(
                    commandId: UUID().uuidString,
                    targets: [.init(consentId: fixture.consentIDs[1].uuidString, outputFullUrls: ["urn:uuid:point", output])]
                ))
            }) { #expect($0.status == .forbidden) }
            try await ClinicalEventStoreTests.expectRows(events: 1, nodes: 2, facts: 1, grants: 1, on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM clinical_attribution_commands").first())
            #expect(try row.decode(column: "count", as: Int.self) == 0)
        }
    }
}


extension ClinicalAttributionHTTPTests {
    private static func seed(_ fixture: ClinicalEventStoreTests.Fixture, on app: Application) async throws -> ClinicalEventReceipt {
        try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            try await ClinicalEventStore(database: app.db).accept(
                ClinicalEventStoreTests.event(source: fixture.source), sourceID: fixture.source.id, targets: [fixture.targets[0]]
            )
        }
    }

    private static func path(_ fixture: ClinicalEventStoreTests.Fixture, event: ClinicalEventReceipt) -> String {
        "\(apiBasePath)/participant/sources/\(fixture.source.id)/events/\(event.eventID)/attributions"
    }

    private static func send(
        _ body: Components.Schemas.EventAttribution, path: String, token: String?, on app: Application
    ) async throws -> Components.Schemas.EventAttributionReceipt {
        var result: Components.Schemas.EventAttributionReceipt?
        try await app.test(.POST, path, beforeRequest: {
            $0.bearerAuth(token)
            try $0.encodeJSONBody(body)
        }) { response in
            try #require(response.status == .ok)
            result = try response.content.decode(Components.Schemas.EventAttributionReceipt.self)
        }
        return try #require(result)
    }
}
