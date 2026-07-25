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
struct PublishedStudyIntegrationTests {
    @Test
    func publishStudyReturnsCreated() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            try await app.test(.POST, "\(apiBasePath)/studies/\(studyId)/publish", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .created)

                let published = try response.content.decode(Components.Schemas.PublishedStudyResponse.self)
                #expect(published.studyId == studyId.uuidString)
                #expect(published.revision == 1)
                #expect(published.visibility == .public)
            }
        }
    }

    @Test
    func publishStudyIncrementsRevision() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            try await app.test(.POST, "\(apiBasePath)/studies/\(studyId)/publish", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .created)
                let published = try response.content.decode(Components.Schemas.PublishedStudyResponse.self)
                #expect(published.revision == 1)
            }

            try await app.test(.POST, "\(apiBasePath)/studies/\(studyId)/publish", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .created)
                let published = try response.content.decode(Components.Schemas.PublishedStudyResponse.self)
                #expect(published.revision == 2)
            }
        }
    }

    @Test
    func listPublishedEmpty() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            try await app.test(.GET, "\(apiBasePath)/studies/\(studyId)/published", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .ok)

                let published = try response.content.decode([Components.Schemas.PublishedStudyResponse].self)
                #expect(published.isEmpty)
            }
        }
    }

    @Test
    func listPublishedReturnsAll() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            try await app.test(.POST, "\(apiBasePath)/studies/\(studyId)/publish", beforeRequest: { req in
                req.bearerAuth(token)
            }) { _ in }

            try await app.test(.POST, "\(apiBasePath)/studies/\(studyId)/publish", beforeRequest: { req in
                req.bearerAuth(token)
            }) { _ in }

            try await app.test(.GET, "\(apiBasePath)/studies/\(studyId)/published", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .ok)

                let published = try response.content.decode([Components.Schemas.PublishedStudyResponse].self)
                #expect(published.count == 2)
            }
        }
    }

    @Test
    func publishStudyNotFound() async throws {
        try await TestApp.withApp { app, token in
            let randomId = UUID()

            try await app.test(.POST, "\(apiBasePath)/studies/\(randomId)/publish", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .notFound)
            }
        }
    }
}
