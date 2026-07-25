//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import StudyPlatformAPIServer
@testable import StudyPlatformServer
import Testing
import VaporTesting


@Suite(.serialized)
struct ComponentScheduleIntegrationTests {
    private func basePath(studyId: UUID, componentId: UUID) -> String {
        "\(apiBasePath)/studies/\(studyId)/components/\(componentId)/schedules"
    }

    private func schedulePath(studyId: UUID, componentId: UUID, scheduleId: UUID) -> String {
        "\(basePath(studyId: studyId, componentId: componentId))/\(scheduleId)"
    }

    private func createFixtures(on database: any FluentKit.Database) async throws -> (studyId: UUID, componentId: UUID) {
        let group = try await GroupFixtures.createGroup(on: database)
        let groupId = try group.requireId()
        let study = try await StudyFixtures.createStudy(on: database, groupId: groupId)
        let studyId = try study.requireId()
        let component = try await ComponentFixtures.createInformationalComponent(on: database, studyId: studyId)
        let componentId = try component.requireId()
        return (studyId, componentId)
    }

    private func scheduleBody() -> [String: Any] {
        [
            "scheduleDefinition": [
                "type": "repeated",
                "pattern": [
                    "type": "daily",
                    "hour": 9
                ] as [String: Any]
            ] as [String: Any],
            "completionPolicy": "anytime",
            "notification": false
        ] as [String: Any]
    }

    private func replaceScheduleBody() -> [String: Any] {
        [
            "scheduleDefinition": [
                "type": "repeated",
                "pattern": [
                    "type": "weekly",
                    "weekday": "monday",
                    "hour": 14,
                    "minute": 30
                ] as [String: Any]
            ] as [String: Any],
            "completionPolicy": "sameDay",
            "notification": true
        ]
    }

    @Test
    func createSchedule() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let groupId = try group.requireId()
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: groupId)
            let studyId = try study.requireId()
            let component = try await ComponentFixtures.createInformationalComponent(on: app.db, studyId: studyId)
            let componentId = try component.requireId()

            try await app.test(.POST, basePath(studyId: studyId, componentId: componentId), beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody(scheduleBody())
            }) { response in
                #expect(response.status == .created)

                let schedule = try response.content.decode(Components.Schemas.ComponentSchedule.self)
                #expect(schedule.id.isEmpty == false)
                #expect(schedule.completionPolicy == .anytime)
                if case .repeated(let value) = schedule.scheduleDefinition {
                    if case .daily(let daily) = value.pattern {
                        #expect(daily.hour == 9)
                    } else {
                        Issue.record("Expected daily pattern")
                    }
                } else {
                    Issue.record("Expected repeated schedule")
                }
            }
        }
    }

    @Test
    func listSchedules() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let groupId = try group.requireId()
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: groupId)
            let studyId = try study.requireId()
            let component = try await ComponentFixtures.createInformationalComponent(on: app.db, studyId: studyId)
            let componentId = try component.requireId()

            try await ComponentFixtures.createSchedule(on: app.db, componentId: componentId)
            try await ComponentFixtures.createSchedule(on: app.db, componentId: componentId)

            try await app.test(.GET, basePath(studyId: studyId, componentId: componentId), beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .ok)

                let schedules = try response.content.decode([Components.Schemas.ComponentSchedule].self)
                #expect(schedules.count == 2)
            }
        }
    }

    @Test
    func getSchedule() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let groupId = try group.requireId()
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: groupId)
            let studyId = try study.requireId()
            let component = try await ComponentFixtures.createInformationalComponent(on: app.db, studyId: studyId)
            let componentId = try component.requireId()

            let schedule = try await ComponentFixtures.createSchedule(on: app.db, componentId: componentId)
            let scheduleId = try schedule.requireId()

            try await app.test(.GET, schedulePath(studyId: studyId, componentId: componentId, scheduleId: scheduleId), beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .ok)

                let result = try response.content.decode(Components.Schemas.ComponentSchedule.self)
                #expect(result.id == scheduleId.uuidString)
                #expect(result.completionPolicy == .anytime)
            }
        }
    }

    @Test
    func getScheduleNotFound() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let groupId = try group.requireId()
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: groupId)
            let studyId = try study.requireId()
            let component = try await ComponentFixtures.createInformationalComponent(on: app.db, studyId: studyId)
            let componentId = try component.requireId()

            let nonExistentId = UUID()
            try await app.test(.GET, schedulePath(studyId: studyId, componentId: componentId, scheduleId: nonExistentId), beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test
    func replaceSchedule() async throws {
        try await TestApp.withApp { app, token in
            let (studyId, componentId) = try await createFixtures(on: app.db)
            let schedule = try await ComponentFixtures.createSchedule(on: app.db, componentId: componentId)
            let scheduleId = try schedule.requireId()

            let updatedBody = replaceScheduleBody()

            try await app.test(.PUT, schedulePath(studyId: studyId, componentId: componentId, scheduleId: scheduleId), beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody(updatedBody)
            }) { response in
                #expect(response.status == .ok)

                let result = try response.content.decode(Components.Schemas.ComponentSchedule.self)
                #expect(result.id == scheduleId.uuidString)
                #expect(result.completionPolicy == .sameDay)
                if case .repeated(let value) = result.scheduleDefinition {
                    if case .weekly(let weekly) = value.pattern {
                        #expect(weekly.weekday == .monday)
                        #expect(weekly.hour == 14)
                        #expect(weekly.minute == 30)
                    } else {
                        Issue.record("Expected weekly pattern")
                    }
                } else {
                    Issue.record("Expected repeated schedule")
                }
            }
        }
    }

    @Test
    func deleteSchedule() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let groupId = try group.requireId()
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: groupId)
            let studyId = try study.requireId()
            let component = try await ComponentFixtures.createInformationalComponent(on: app.db, studyId: studyId)
            let componentId = try component.requireId()

            let schedule = try await ComponentFixtures.createSchedule(on: app.db, componentId: componentId)
            let scheduleId = try schedule.requireId()

            try await app.test(.DELETE, schedulePath(studyId: studyId, componentId: componentId, scheduleId: scheduleId), beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .noContent)
            }

            try await app.test(.GET, schedulePath(studyId: studyId, componentId: componentId, scheduleId: scheduleId), beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test
    func deleteScheduleNotFound() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let groupId = try group.requireId()
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: groupId)
            let studyId = try study.requireId()
            let component = try await ComponentFixtures.createInformationalComponent(on: app.db, studyId: studyId)
            let componentId = try component.requireId()

            let nonExistentId = UUID()
            try await app.test(.DELETE, schedulePath(studyId: studyId, componentId: componentId, scheduleId: nonExistentId), beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test
    func componentNotFound() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let groupId = try group.requireId()
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: groupId)
            let studyId = try study.requireId()
            let nonExistentComponentId = UUID()

            try await app.test(.GET, basePath(studyId: studyId, componentId: nonExistentComponentId), beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .notFound)
            }
        }
    }
}
