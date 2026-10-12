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


@Suite(.serialized)
struct PublishedStudyIntegrationTests {
    @Test
    func publishStudyReturnsCreated() async throws {
        try await PublicationWorkflowFixtures.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            let response = try await PublicationWorkflowFixtures.publish(studyId, app: app, token: token)
            #expect(response.status == .created)

            let published = try response.content.decode(Components.Schemas.PublishedStudyResponse.self)
            #expect(published.studyId == studyId.uuidString)
            #expect(published.revision == 1)
            #expect(published.visibility == .public)
        }
    }

    @Test
    func publishStudyIncrementsRevision() async throws {
        try await PublicationWorkflowFixtures.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            for revision in 1...2 {
                let response = try await PublicationWorkflowFixtures.publish(studyId, app: app, token: token)
                #expect(response.status == .created)
                let published = try response.content.decode(Components.Schemas.PublishedStudyResponse.self)
                #expect(published.revision == revision)
            }
        }
    }

    @Test
    func listPublishedEmpty() async throws {
        try await PublicationWorkflowFixtures.withApp { app, token in
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
        try await PublicationWorkflowFixtures.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            for _ in 1...2 {
                let response = try await PublicationWorkflowFixtures.publish(studyId, app: app, token: token)
                try #require(response.status == .created)
            }

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
        try await PublicationWorkflowFixtures.withApp { app, token in
            let randomId = UUID()

            try await app.test(.POST, "\(apiBasePath)/studies/\(randomId)/publish", beforeRequest: { req in
                req.bearerAuth(token)
                req.headers.replaceOrAdd(name: "If-Match", value: "\"\(UUID())\"")
                try req.encodeJSONBody(Components.Schemas.StudyPublicationInput(validationId: UUID().uuidString))
            }) { response in
                #expect(response.status == .notFound)
            }
        }
    }
}
