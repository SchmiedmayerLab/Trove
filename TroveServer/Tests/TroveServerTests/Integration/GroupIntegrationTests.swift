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
struct GroupIntegrationTests {
    @Test
    func listGroupsReturnsOnlyAccessible() async throws {
        try await TestApp.withApp(token: .researcher(groups: ["/Group A/admin"])) { app, token in
            let groupA = try await GroupFixtures.createGroup(on: app.db, name: "Group A")
            try await GroupFixtures.createGroup(on: app.db, name: "Group B")

            try await app.test(.GET, "\(apiBasePath)/groups", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .ok)

                let groups = try response.content.decode([Components.Schemas.GroupResponse].self)
                #expect(groups.count == 1)
                #expect(groups.first?.name == "Group A")
                let expectedId = try groupA.requireId().uuidString
                #expect(groups.first?.id == expectedId)
            }
        }
    }

    @Test
    func listGroupsReturnsMultipleAccessible() async throws {
        try await TestApp.withApp(token: .researcher(groups: ["/Group A/researcher", "/Group B/admin"])) { app, token in
            try await GroupFixtures.createGroup(on: app.db, name: "Group A")
            try await GroupFixtures.createGroup(on: app.db, name: "Group B")
            try await GroupFixtures.createGroup(on: app.db, name: "Group C")

            try await app.test(.GET, "\(apiBasePath)/groups", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .ok)

                let groups = try response.content.decode([Components.Schemas.GroupResponse].self)
                #expect(groups.count == 2)
                let names = Set(groups.map(\.name))
                #expect(names == ["Group A", "Group B"])
            }
        }
    }

    @Test
    func getGroupByIdAllowed() async throws {
        try await TestApp.withApp(token: .researcher(groups: ["/Test Group/researcher"])) { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let groupId = try group.requireId()

            try await app.test(.GET, "\(apiBasePath)/groups/\(groupId)", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .ok)

                let result = try response.content.decode(Components.Schemas.GroupResponse.self)
                #expect(result.id == groupId.uuidString)
                #expect(result.name == "Test Group")
            }
        }
    }

    @Test
    func getGroupByIdForbidden() async throws {
        try await TestApp.withApp(token: .researcher(groups: ["/Other Group/admin"])) { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let groupId = try group.requireId()

            try await app.test(.GET, "\(apiBasePath)/groups/\(groupId)", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    @Test
    func getGroupByIdNotFound() async throws {
        try await TestApp.withApp { app, token in
            let nonExistentId = UUID()

            try await app.test(.GET, "\(apiBasePath)/groups/\(nonExistentId)", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .notFound)
            }
        }
    }
}
