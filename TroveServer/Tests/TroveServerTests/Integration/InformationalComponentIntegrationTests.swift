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
struct InformationalComponentIntegrationTests {
    @Test
    func createInformationalComponent() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            try await app.test(
                .POST,
                "\(apiBasePath)/studies/\(studyId)/components/informational",
                beforeRequest: { req in
                    req.bearerAuth(token)
                    try req.encodeJSONBody(createRequestBody(name: "Test Article"))
                }
            ) { response in
                #expect(response.status == .created)

                let component = try response.content.decode(
                    Components.Schemas.InformationalComponentResponse.self
                )
                #expect(component.name == "Test Article")
                #expect(component.id.isEmpty == false)
            }
        }
    }

    @Test
    func getInformationalComponent() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            let component = try await ComponentFixtures.createInformationalComponent(
                on: app.db,
                studyId: studyId,
                name: "Test Article"
            )
            let componentId = try component.requireId()

            try await app.test(
                .GET,
                "\(apiBasePath)/studies/\(studyId)/components/informational/\(componentId)",
                beforeRequest: { req in
                    req.bearerAuth(token)
                }
            ) { response in
                #expect(response.status == .ok)

                let responseComponent = try response.content.decode(
                    Components.Schemas.InformationalComponentResponse.self
                )
                #expect(responseComponent.id == componentId.uuidString)
                #expect(responseComponent.name == "Test Article")
            }
        }
    }

    @Test
    func getInformationalComponentNotFound() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()
            let nonExistentId = UUID()

            try await app.test(
                .GET,
                "\(apiBasePath)/studies/\(studyId)/components/informational/\(nonExistentId)",
                beforeRequest: { req in
                    req.bearerAuth(token)
                }
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test
    func updateInformationalComponent() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            let component = try await ComponentFixtures.createInformationalComponent(
                on: app.db,
                studyId: studyId,
                name: "Original Name"
            )
            let componentId = try component.requireId()

            try await app.test(
                .PUT,
                "\(apiBasePath)/studies/\(studyId)/components/informational/\(componentId)",
                beforeRequest: { req in
                    req.bearerAuth(token)
                    try req.encodeJSONBody(createRequestBody(name: "Updated Name"))
                }
            ) { response in
                #expect(response.status == .ok)

                let updated = try response.content.decode(
                    Components.Schemas.InformationalComponentResponse.self
                )
                #expect(updated.name == "Updated Name")
            }
        }
    }

    private func createRequestBody(name: String) -> [String: Any] {
        [
            "name": name,
            "data": [
                "en-US": [
                    "title": "Title",
                    "content": "Content"
                ]
            ]
        ]
    }
}
