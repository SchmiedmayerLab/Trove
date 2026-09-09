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


struct ParticipantIdentityTests {
    private static let otherIssuer = "https://other-identity.example.test/realms/trove"
    private static let subject = "shared-subject"

    @Test
    func profileLookupAndUpdatesDoNotCrossIssuers() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.subject)) { app, token in
            let foreign = try await ParticipantFixtures.createParticipant(
                on: app.db, identityProviderId: Self.subject, identityProviderIssuer: Self.otherIssuer
            )
            try await app.test(.GET, "\(apiBasePath)/participant/profile", beforeRequest: { request in
                request.bearerAuth(token)
            }) { response in
                #expect(response.status == .notFound)
            }
            try await app.test(.PUT, "\(apiBasePath)/participant/profile", beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeJSONBody(ParticipantFixtures.profileBody(firstName: "Changed"))
            }) { response in
                #expect(response.status == .notFound)
            }
            let retained = try #require(try await Participant.find(foreign.requireId(), on: app.db))
            #expect(retained.firstName == "Jane")
        }
    }

    @Test
    func sameSubjectCanRegisterSeparateProfilesInDifferentIssuers() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.subject)) { app, token in
            let foreign = try await ParticipantFixtures.createParticipant(
                on: app.db, identityProviderId: Self.subject, identityProviderIssuer: Self.otherIssuer
            )
            try await app.test(.POST, "\(apiBasePath)/participant/profile", beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeJSONBody(ParticipantFixtures.profileBody(firstName: "Local"))
            }) { response in
                #expect(response.status == .created)
            }
            try await app.test(.GET, "\(apiBasePath)/participant/profile", beforeRequest: { request in
                request.bearerAuth(token)
            }) { response in
                #expect(response.status == .ok)
                let profile = try response.content.decode(Components.Schemas.ParticipantProfile.self)
                #expect(profile.firstName == "Local")
                #expect(profile.id != foreign.id?.uuidString)
            }
            let repository = ProfileRepository(database: app.db)
            let local = try #require(try await repository.findByIdentity(issuer: TestApp.issuer, subject: Self.subject))
            let other = try #require(try await repository.findByIdentity(issuer: Self.otherIssuer, subject: Self.subject))
            #expect(local.id != other.id)
            #expect(other.id == foreign.id)
            #expect(try await Participant.query(on: app.db).count() == 2)
        }
    }

    @Test
    func completeIdentityIsUnique() async throws {
        try await TestApp.withApp { app, _ in
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.subject)
            await #expect {
                try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.subject)
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            #expect(try await Participant.query(on: app.db).count() == 1)
        }
    }

    @Test(arguments: ["identity_provider_issuer", "identity_provider_id"], [false, true])
    func identityCannotBeEmptyOrMissing(column: String, missing: Bool) async throws {
        try await TestApp.withApp { app, _ in
            let participant = try await ParticipantFixtures.createParticipant(on: app.db)
            let id = try participant.requireId()
            let sql = try #require(app.db as? any SQLDatabase)
            await #expect {
                if missing {
                    try await sql.raw("UPDATE participants SET \(ident: column) = NULL WHERE id = \(bind: id)").run()
                } else {
                    try await sql.raw("UPDATE participants SET \(ident: column) = '' WHERE id = \(bind: id)").run()
                }
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            let retained = try #require(try await Participant.find(id, on: app.db))
            #expect(retained.identityProviderIssuer == TestApp.issuer)
            #expect(retained.identityProviderId == "test-participant")
        }
    }
}
