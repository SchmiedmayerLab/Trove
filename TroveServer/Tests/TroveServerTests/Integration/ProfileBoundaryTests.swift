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


struct ProfileBoundaryTests {
    private static func input(
        date: String = "2000-01-15",
        gender: Components.Schemas.GenderIdentity = .female
    ) -> Components.Schemas.ParticipantProfileInput {
        .init(
            firstName: "Jane",
            lastName: "Doe",
            gender: gender,
            dateOfBirth: date,
            region: "US",
            language: "en",
            phoneNumber: "+1234567890"
        )
    }

    @Test(arguments: [
        (Components.Schemas.GenderIdentity.female, GenderIdentity.female), (.male, .male),
        (.transgender, .transgender), (.nonBinary, .nonBinary), (.preferNotToState, .preferNotToState)
    ])
    func genderSurvivesAPIDatabaseAndResponseMapping(api: Components.Schemas.GenderIdentity, domain: GenderIdentity) async throws {
        let input = try ParticipantProfileInput(Self.input(gender: api))
        #expect(input.gender == domain)
        try await TestApp.withApp { app, _ in
            let participant = try await ParticipantFixtures.createParticipant(on: app.db)
            participant.gender = input.gender
            try await participant.save(on: app.db)
            let stored = try #require(try await Participant.find(participant.requireId(), on: app.db))
            #expect(stored.gender == domain)
            #expect(try Components.Schemas.ParticipantProfile(stored).gender == api)
        }
    }

    @Test(arguments: [("1970-01-01", 0.0), ("2000-01-01", 946_684_800.0), ("2000-02-29", 951_782_400.0)])
    func dateOnlyUsesExactGregorianUTCDay(value: String, epoch: Double) throws {
        let input = try ParticipantProfileInput(Self.input(date: value))
        #expect(input.dateOfBirth.timeIntervalSince1970 == epoch)
    }

    @Test(arguments: [
        "2000-1-15", "2000-01-5", " 2000-01-15", "2000-01-15 ", "2000-01-15suffix",
        "2000-01-15T00:00:00Z", "2000-02-30", "1900-02-29", "2000-00-01", "2000-13-01", "2000-01-00", ""
    ])
    func malformedDateOnlyIsNotNormalized(value: String) {
        #expect {
            try ParticipantProfileInput(Self.input(date: value))
        } throws: { ($0 as? ServerError)?.status.code == 400 }
    }

    @Test(arguments: ["unknown", "Female", "", "female "])
    func databaseRejectsUnsupportedGender(value: String) async throws {
        try await TestApp.withApp { app, _ in
            let participant = try await ParticipantFixtures.createParticipant(on: app.db)
            let id = try participant.requireId()
            let sql = try #require(app.db as? any SQLDatabase)
            await #expect {
                try await sql.raw("UPDATE participants SET gender = \(bind: value) WHERE id = \(bind: id)").run()
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            let stored = try #require(try await Participant.find(id, on: app.db))
            #expect(stored.gender == .female)
        }
    }

    @Test(arguments: ["2000-1-15", "2000-02-30"])
    func invalidProfileUpdateLeavesStoredDataUnchanged(value: String) async throws {
        try await TestApp.withApp(token: .participant(subject: "profile-boundary")) { app, token in
            try await app.test(.POST, "\(apiBasePath)/participant/profile", beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeJSONBody(ParticipantFixtures.profileBody())
            }) { response in
                #expect(response.status == .created)
            }
            var invalid = ParticipantFixtures.profileBody(firstName: "Changed")
            invalid["dateOfBirth"] = value
            try await app.test(.PUT, "\(apiBasePath)/participant/profile", beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeJSONBody(invalid)
            }) { response in
                #expect(response.status == .badRequest)
            }
            try await app.test(.GET, "\(apiBasePath)/participant/profile", beforeRequest: { $0.bearerAuth(token) }) { response in
                let profile = try response.content.decode(Components.Schemas.ParticipantProfile.self)
                #expect(profile.firstName == "Jane")
                #expect(profile.dateOfBirth == "2000-01-15")
            }
        }
    }
}
