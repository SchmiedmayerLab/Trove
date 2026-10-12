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
struct HealthDataComponentIntegrationTests {
    @Test
    func createHealthDataComponent() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()
            let draftRevision = study.draftRevision

            try await app.test(
                .POST,
                "\(apiBasePath)/studies/\(studyId)/components/health-data",
                beforeRequest: { req in
                    req.bearerAuth(token)
                    req.headers.replaceOrAdd(name: "If-Match", value: "\"\(draftRevision)\"")
                    try req.encodeJSONBody(createRequestBody(name: "Heart Rate Collection"))
                }
            ) { response in
                #expect(response.status == .created)

                let component = try response.content.decode(
                    Components.Schemas.HealthDataComponentResponse.self
                )
                #expect(component.name == "Heart Rate Collection")
                #expect(component.id.isEmpty == false)
            }
        }
    }

    @Test
    func getHealthDataComponent() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            let component = try await ComponentFixtures.createHealthDataComponent(
                on: app.db,
                studyId: studyId,
                name: "Test Health Data"
            )
            let componentId = try component.requireId()

            try await app.test(
                .GET,
                "\(apiBasePath)/studies/\(studyId)/components/health-data/\(componentId)",
                beforeRequest: { req in
                    req.bearerAuth(token)
                }
            ) { response in
                #expect(response.status == .ok)

                let responseComponent = try response.content.decode(
                    Components.Schemas.HealthDataComponentResponse.self
                )
                #expect(responseComponent.id == componentId.uuidString)
                #expect(responseComponent.name == "Test Health Data")
            }
        }
    }

    @Test
    func getHealthDataComponentNotFound() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()
            let nonExistentId = UUID()

            try await app.test(
                .GET,
                "\(apiBasePath)/studies/\(studyId)/components/health-data/\(nonExistentId)",
                beforeRequest: { req in
                    req.bearerAuth(token)
                }
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test
    func updateHealthDataComponent() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            let component = try await ComponentFixtures.createHealthDataComponent(
                on: app.db,
                studyId: studyId,
                name: "Original Name"
            )
            let componentId = try component.requireId()
            let draftRevision = study.draftRevision

            try await app.test(
                .PUT,
                "\(apiBasePath)/studies/\(studyId)/components/health-data/\(componentId)",
                beforeRequest: { req in
                    req.bearerAuth(token)
                    req.headers.replaceOrAdd(name: "If-Match", value: "\"\(draftRevision)\"")
                    try req.encodeJSONBody(createRequestBody(name: "Updated Name"))
                }
            ) { response in
                #expect(response.status == .ok)

                let updated = try response.content.decode(
                    Components.Schemas.HealthDataComponentResponse.self
                )
                #expect(updated.name == "Updated Name")
            }
        }
    }

    private func createRequestBody(name: String) -> [String: Any] {
        [
            "name": name,
            "data": [
                "sampleTypes": [
                    "HKQuantityType;HKQuantityTypeIdentifierHeartRate",
                    "HKQuantityType;HKQuantityTypeIdentifierStepCount"
                ],
                "historicalDataCollection": [
                    "enabled": false
                ]
            ]
        ]
    }
}
