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


struct SourceBindingHTTPTests {
    private static let subject = "source-owner"

    @Test
    func registrationRetryAndRevocationPreserveTheSameStream() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.subject)) { app, token in
            let participant = try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.subject)
            let nonce = UUID().uuidString
            let first = try await Self.register(on: app, token: token, nonce: nonce)
            let retry = try await Self.register(on: app, token: token, nonce: nonce)
            #expect(first == retry)
            #expect(first.kind == .participantApp)
            #expect(first.producerInstance == first.id)
            #expect(first.eventIdentifierSystem == "urn:uuid:\(first.id)")
            #expect(first.participantIdentifier.system == TestApp.issuer + "/trove/participants")
            #expect(first.participantIdentifier.value == participant.id?.uuidString.lowercased())
            #expect(first.revokedAt == nil)
            let systems = try first.pseudonymousIdentifierSystems.groveSystems()
            #expect(Set(systems.all).count == 10)
            #expect(!systems.all.contains { $0.rawValue == first.eventIdentifierSystem })
            try await app.test(.GET, "\(apiBasePath)/participant/sources/\(first.id)", beforeRequest: { $0.bearerAuth(token) }) { response in
                #expect(response.status == .ok)
                let loaded = try response.content.decode(Components.Schemas.ParticipantSource.self)
                #expect(loaded == first)
            }
            try await app.test(.POST, "\(apiBasePath)/participant/sources/\(first.id)/revoke", beforeRequest: { $0.bearerAuth(token) }) { response in
                #expect(response.status == .ok)
                let revoked = try response.content.decode(Components.Schemas.ParticipantSource.self)
                #expect(revoked.revokedAt != nil)
            }
            let revoked = try await Self.register(on: app, token: token, nonce: nonce)
            #expect(revoked.id == first.id)
            #expect(revoked.pseudonymousIdentifierSystems == first.pseudonymousIdentifierSystems)
            #expect(revoked.revokedAt != nil)
            #expect(try await Enrollment.query(on: app.db).count() == 0)
            let sql = try #require(app.db as? any SQLDatabase)
            let audit = try #require(try await sql.raw("SELECT count(*) AS count FROM audit_events").first())
            #expect(try audit.decode(column: "count", as: Int.self) == 2)
        }
    }

    @Test(arguments: [false, true])
    func anotherParticipantCannotReadOrRevokeAStream(revoke: Bool) async throws {
        try await TestApp.withApp(token: .participant(subject: "other-participant")) { app, token in
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.subject)
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: "other-participant")
            let owner = AuthContext(
                issuer: TestApp.issuer,
                subject: Self.subject,
                email: "owner@example.test",
                roles: [TestApp.participantRole],
                groups: [],
                researcherRole: TestApp.researcherRole,
                participantRole: TestApp.participantRole
            )
            let source = try await AuthContext.$current.withValue(owner) {
                try await SourceBindingService(database: app.db).register(registrationID: UUID())
            }
            let suffix = revoke ? "/revoke" : ""
            try await app.test(revoke ? .POST : .GET, "\(apiBasePath)/participant/sources/\(source.id)\(suffix)", beforeRequest: {
                $0.bearerAuth(token)
            }) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test(arguments: [TestApp.Token.none, .researcher(), .participant(subject: "missing-profile")])
    func registrationRequiresAnAuthenticatedParticipantProfile(identity: TestApp.Token) async throws {
        try await TestApp.withApp(token: identity) { app, token in
            let expected: HTTPStatus = switch identity {
            case .none: .unauthorized
            case .researcher: .forbidden
            case .participant: .notFound
            }
            try await app.test(.POST, "\(apiBasePath)/participant/sources", beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeJSONBody(["registrationID": UUID().uuidString])
            }) { response in
                #expect(response.status == expected)
            }
        }
    }

    @Test(arguments: ["invalid-uuid", "caller-namespace"])
    func registrationRejectsInvalidNonceAndCallerAssignedAuthority(input: String) async throws {
        try await TestApp.withApp(token: .participant(subject: Self.subject)) { app, token in
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.subject)
            let body: [String: String] = input == "invalid-uuid"
                ? ["registrationID": "not-a-uuid"]
                : ["registrationID": UUID().uuidString, "eventIdentifierSystem": "https://attacker.example.test"]
            try await app.test(.POST, "\(apiBasePath)/participant/sources", beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeJSONBody(body)
            }) { response in
                #expect(response.status == .badRequest)
            }
            let sql = try #require(app.db as? any SQLDatabase)
            let row = try #require(try await sql.raw("SELECT count(*) AS count FROM source_bindings").first())
            #expect(try row.decode(column: "count", as: Int.self) == 0)
        }
    }
}


extension SourceBindingHTTPTests {
    private static func register(on app: Application, token: String?, nonce: String) async throws -> Components.Schemas.ParticipantSource {
        var result: Components.Schemas.ParticipantSource?
        try await app.test(.POST, "\(apiBasePath)/participant/sources", beforeRequest: { request in
            request.bearerAuth(token)
            try request.encodeJSONBody(["registrationID": nonce])
        }) { response in
            try #require(response.status == .ok)
            result = try response.content.decode(Components.Schemas.ParticipantSource.self)
        }
        return try #require(result)
    }
}
