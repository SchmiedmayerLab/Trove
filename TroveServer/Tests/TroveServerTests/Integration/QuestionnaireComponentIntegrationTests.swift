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
struct QuestionnaireComponentIntegrationTests {
    @Test
    func createQuestionnaireComponent() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()
            let draftRevision = study.draftRevision

            try await app.test(
                .POST,
                "\(apiBasePath)/studies/\(studyId)/components/questionnaire",
                beforeRequest: { req in
                    req.bearerAuth(token)
                    req.headers.replaceOrAdd(name: "If-Match", value: "\"\(draftRevision)\"")
                    try req.encodeJSONBody(createRequestBody(name: "Test Questionnaire"))
                }
            ) { response in
                #expect(response.status == .created)

                let component = try response.content.decode(
                    Components.Schemas.QuestionnaireComponentResponse.self
                )
                #expect(component.name == "Test Questionnaire")
                #expect(component.id.isEmpty == false)
            }
        }
    }

    @Test
    func getQuestionnaireComponent() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            let component = try await ComponentFixtures.createQuestionnaireComponent(
                on: app.db,
                studyId: studyId,
                name: "Test Questionnaire"
            )
            let componentId = try component.requireId()

            try await app.test(
                .GET,
                "\(apiBasePath)/studies/\(studyId)/components/questionnaire/\(componentId)",
                beforeRequest: { req in
                    req.bearerAuth(token)
                }
            ) { response in
                #expect(response.status == .ok)

                let responseComponent = try response.content.decode(
                    Components.Schemas.QuestionnaireComponentResponse.self
                )
                #expect(responseComponent.id == componentId.uuidString)
                #expect(responseComponent.name == "Test Questionnaire")
            }
        }
    }

    @Test
    func getQuestionnaireComponentNotFound() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()
            let nonExistentId = UUID()

            try await app.test(
                .GET,
                "\(apiBasePath)/studies/\(studyId)/components/questionnaire/\(nonExistentId)",
                beforeRequest: { req in
                    req.bearerAuth(token)
                }
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test
    func updateQuestionnaireComponent() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            let component = try await ComponentFixtures.createQuestionnaireComponent(
                on: app.db,
                studyId: studyId,
                name: "Original Name"
            )
            let componentId = try component.requireId()
            let draftRevision = study.draftRevision

            try await app.test(
                .PUT,
                "\(apiBasePath)/studies/\(studyId)/components/questionnaire/\(componentId)",
                beforeRequest: { req in
                    req.bearerAuth(token)
                    req.headers.replaceOrAdd(name: "If-Match", value: "\"\(draftRevision)\"")
                    try req.encodeJSONBody(createRequestBody(name: "Updated Name"))
                }
            ) { response in
                #expect(response.status == .ok)

                let updated = try response.content.decode(
                    Components.Schemas.QuestionnaireComponentResponse.self
                )
                #expect(updated.name == "Updated Name")
            }
        }
    }

    @Test
    func multilingualResourceRoundTripsWithItsExactBytesAndLanguages() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()
            for fixture in try MultilingualQuestionnaireFixture.all() {
                let revision = try #require(try await Study.find(studyId, on: app.db)).draftRevision
                let created = try await app.sendRequest(.POST, "\(apiBasePath)/studies/\(studyId)/components/questionnaire", beforeRequest: { req in
                    req.bearerAuth(token)
                    req.headers.replaceOrAdd(name: "If-Match", value: "\"\(revision)\"")
                    try req.encodeJSONBody(Components.Schemas.QuestionnaireComponentInput(name: fixture.file, data: try fixture.content()))
                })
                #expect(created.status == .created)
                let component = try created.content.decode(Components.Schemas.QuestionnaireComponentResponse.self)
                let componentId = try #require(UUID(uuidString: component.id))
                #expect(Data(component.data.questionnaire.utf8) == (try fixture.bytes()))
                #expect(component.language == fixture.language)
                #expect(component.translationLanguages == fixture.translationLanguages)

                let stored = try #require(try await Component.find(componentId, on: app.db))
                guard case .questionnaire(let content) = stored.data else {
                    Issue.record("Expected one stored questionnaire resource")
                    continue
                }
                #expect(Data(content.questionnaire.utf8) == (try fixture.bytes()))

                let read = try await app.sendRequest(.GET, "\(apiBasePath)/studies/\(studyId)/components/questionnaire/\(componentId)", beforeRequest: { req in
                    req.bearerAuth(token)
                })
                #expect(try read.content.decode(Components.Schemas.QuestionnaireComponentResponse.self) == component)
            }
        }
    }

    @Test
    func draftLanguagesAreReportedWithoutValidatingTheResource() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            try await app.test(
                .POST,
                "\(apiBasePath)/studies/\(study.requireId())/components/questionnaire",
                beforeRequest: { req in
                    req.bearerAuth(token)
                    req.headers.replaceOrAdd(name: "If-Match", value: "\"\(study.draftRevision)\"")
                    try req.encodeJSONBody(createRequestBody(name: "Unfinished"))
                }
            ) { response in
                #expect(response.status == .created)
                let component = try response.content.decode(Components.Schemas.QuestionnaireComponentResponse.self)
                #expect(component.data.questionnaire == "{}")
                #expect(component.language == nil)
                #expect(component.translationLanguages.isEmpty)
            }
        }
    }

    private func createRequestBody(name: String) -> [String: Any] {
        [
            "name": name,
            "data": [
                "questionnaire": "{}"
            ]
        ]
    }
}
