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
struct ComponentIntegrationTests {
    @Test
    func listComponentsEmpty() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            try await app.test(.GET, "\(apiBasePath)/studies/\(studyId)/components", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .ok)

                let components = try response.content.decode([Components.Schemas.Component].self)
                #expect(components.isEmpty)
            }
        }
    }

    @Test
    func listComponentsWithData() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            try await ComponentFixtures.createHealthDataComponent(on: app.db, studyId: studyId)
            try await ComponentFixtures.createQuestionnaireComponent(on: app.db, studyId: studyId)
            try await ComponentFixtures.createInformationalComponent(on: app.db, studyId: studyId)

            try await app.test(.GET, "\(apiBasePath)/studies/\(studyId)/components", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .ok)

                let components = try response.content.decode([Components.Schemas.Component].self)
                #expect(components.count == 3)
            }
        }
    }

    @Test
    func listComponentsStudyNotFound() async throws {
        try await TestApp.withApp { app, token in
            let nonExistentId = UUID()

            try await app.test(.GET, "\(apiBasePath)/studies/\(nonExistentId)/components", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test
    func deleteComponent() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            let component = try await ComponentFixtures.createHealthDataComponent(
                on: app.db,
                studyId: studyId
            )
            let componentId = try component.requireId()

            try await app.test(.DELETE, "\(apiBasePath)/studies/\(studyId)/components/\(componentId)", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .noContent)
            }

            try await app.test(.GET, "\(apiBasePath)/studies/\(studyId)/components", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                let components = try response.content.decode([Components.Schemas.Component].self)
                #expect(components.isEmpty)
            }
        }
    }

    @Test
    func deleteComponentNotFound() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()
            let nonExistentId = UUID()

            try await app.test(.DELETE, "\(apiBasePath)/studies/\(studyId)/components/\(nonExistentId)", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test
    func deleteStudyCascadesComponents() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            try await ComponentFixtures.createHealthDataComponent(on: app.db, studyId: studyId)

            try await app.test(.DELETE, "\(apiBasePath)/studies/\(studyId)", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .noContent)
            }

            let remainingComponents = try await Component.query(on: app.db).all()
            #expect(remainingComponents.isEmpty)
        }
    }
}
