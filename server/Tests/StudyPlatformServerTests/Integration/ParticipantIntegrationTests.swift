//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import StudyPlatformAPIServer
@testable import StudyPlatformServer
import Testing
import VaporTesting


@Suite(.serialized)
struct ParticipantIntegrationTests {
    private static let profileBody = ParticipantFixtures.profileBody()

    // MARK: - Profile Tests

    @Test
    func createProfileReturnsCreated() async throws {
        try await TestApp.withApp(token: .participant(subject: "profile-create-user", email: "jane@example.com")) { app, token in
            try await app.test(.POST, "\(apiBasePath)/participant/profile", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody(Self.profileBody)
            }) { response in
                #expect(response.status == .created)

                let profile = try response.content.decode(Components.Schemas.ParticipantProfile.self)
                #expect(profile.id.isEmpty == false)
                #expect(profile.firstName == "Jane")
                #expect(profile.lastName == "Doe")
                #expect(profile.email == "jane@example.com")
                #expect(profile.dateOfBirth == "2000-01-15")
                #expect(profile.region == "US")
                #expect(profile.language == "en")
                #expect(profile.phoneNumber == "+1234567890")
            }
        }
    }

    @Test
    func createProfileReturnsConflict() async throws {
        try await TestApp.withApp(token: .participant(subject: "profile-conflict-user")) { app, token in
            try await app.test(.POST, "\(apiBasePath)/participant/profile", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody(Self.profileBody)
            }) { response in
                #expect(response.status == .created)
            }

            try await app.test(.POST, "\(apiBasePath)/participant/profile", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody(Self.profileBody)
            }) { response in
                #expect(response.status == .conflict)
            }
        }
    }

    @Test
    func getProfileReturnsOk() async throws {
        try await TestApp.withApp(token: .participant(subject: "profile-get-user")) { app, token in
            try await app.test(.POST, "\(apiBasePath)/participant/profile", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody(Self.profileBody)
            }) { response in
                #expect(response.status == .created)
            }

            try await app.test(.GET, "\(apiBasePath)/participant/profile", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .ok)

                let profile = try response.content.decode(Components.Schemas.ParticipantProfile.self)
                #expect(profile.firstName == "Jane")
            }
        }
    }

    @Test
    func getProfileReturnsNotFound() async throws {
        try await TestApp.withApp(token: .participant(subject: "profile-notfound-user")) { app, token in
            try await app.test(.GET, "\(apiBasePath)/participant/profile", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test
    func updateProfileReturnsOk() async throws {
        try await TestApp.withApp(token: .participant(subject: "profile-update-user")) { app, token in
            try await app.test(.POST, "\(apiBasePath)/participant/profile", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody(Self.profileBody)
            }) { response in
                #expect(response.status == .created)
            }

            var updatedBody = Self.profileBody
            updatedBody["firstName"] = "Updated"
            updatedBody["lastName"] = "Smith"
            updatedBody["dateOfBirth"] = "1995-06-20"

            try await app.test(.PUT, "\(apiBasePath)/participant/profile", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody(updatedBody)
            }) { response in
                #expect(response.status == .ok)

                let profile = try response.content.decode(Components.Schemas.ParticipantProfile.self)
                #expect(profile.firstName == "Updated")
                #expect(profile.lastName == "Smith")
                #expect(profile.dateOfBirth == "1995-06-20")
            }
        }
    }

    @Test
    func updateProfileReturnsNotFound() async throws {
        try await TestApp.withApp(token: .participant(subject: "profile-update-notfound-user")) { app, token in
            try await app.test(.PUT, "\(apiBasePath)/participant/profile", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody(Self.profileBody)
            }) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    // MARK: - Browse Studies Tests

    @Test
    func browseStudiesReturnsPublicOnly() async throws {
        try await TestApp.withApp(token: .participant(subject: "browse-public-user")) { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let groupId = try group.requireId()

            let publicStudy = try await StudyFixtures.createStudy(on: app.db, groupId: groupId, title: "Public Study")
            let publicStudyId = try publicStudy.requireId()
            try await PublishedStudyFixtures.createPublishedStudy(on: app.db, studyId: publicStudyId, title: "Public Study")

            let unlistedStudy = try await StudyFixtures.createStudy(on: app.db, groupId: groupId, title: "Unlisted Study")
            let unlistedStudyId = try unlistedStudy.requireId()
            try await PublishedStudyFixtures.createPublishedStudy(
                on: app.db, studyId: unlistedStudyId, visibility: .unlisted, title: "Unlisted Study"
            )

            try await app.test(.GET, "\(apiBasePath)/participant/studies", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .ok)

                let studies = try response.content.decode([Components.Schemas.PublishedStudyListItem].self)
                #expect(studies.count == 1)
                #expect(studies.first?.metadata.title[.enUS] == "Public Study")
            }
        }
    }

    @Test
    func browseStudiesReturnsEmpty() async throws {
        try await TestApp.withApp(token: .participant(subject: "browse-empty-user")) { app, token in
            try await app.test(.GET, "\(apiBasePath)/participant/studies", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .ok)

                let studies = try response.content.decode([Components.Schemas.PublishedStudyListItem].self)
                #expect(studies.isEmpty)
            }
        }
    }
}
