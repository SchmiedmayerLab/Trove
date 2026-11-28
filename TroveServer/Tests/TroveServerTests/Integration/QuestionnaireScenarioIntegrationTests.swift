//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Synchronization
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


/// The scenarios operation evaluates the exact stored resource for anyone who may inspect the draft, and changes nothing.
struct QuestionnaireScenarioIntegrationTests {
    private struct StoredFixture {
        let component: Component
        let bytes: Data
        let json: ScenarioJSON
    }

    private struct Case {
        let component: Component
        let input: Components.Schemas.QuestionnaireScenarioInput
        let status: HTTPStatus
    }

    private static var grantor: AuthContext {
        AuthContext(
            issuer: TestApp.issuer,
            subject: "grantor",
            email: "grantor@example.test",
            roles: [TestApp.researcherRole],
            groups: ["/Test Group/admin"],
            researcherRole: TestApp.researcherRole,
            participantRole: TestApp.participantRole,
            executingClientID: "trove-cli",
            clientAccess: .interactive,
            delegationID: nil
        )
    }

    private static var authority: GrantorAuthorityProvider {
        .init { actor in
            .init(issuer: actor.issuer, subject: actor.subject, enabled: true, roles: [TestApp.researcherRole], groups: ["/Test Group/admin"])
        }
    }

    private static func setBody(_ input: Components.Schemas.QuestionnaireScenarioInput, in request: inout TestingHTTPRequest) throws {
        request.headers.contentType = .json
        request.body = .init(data: try JSONEncoder().encode(input))
    }

    private static func path(_ study: Study, _ component: Component) throws -> String {
        "\(apiBasePath)/studies/\(try study.requireId())/components/\(try component.requireId())/scenarios"
    }

    private static func storedFixture(_ file: String, study: Study, on app: Application) async throws -> StoredFixture {
        let fixture = try #require(try QuestionnaireScenarioFixture.all().first { $0.file == file })
        let json = try fixture.json()
        let bytes = try JSONEncoder().encode(try #require(json["questionnaire"]))
        let component = Component(
            studyId: try study.requireId(),
            data: .questionnaire(.init(questionnaire: String(decoding: bytes, as: UTF8.self))),
            name: "Scenario fixture"
        )
        try await component.create(on: app.db)
        return StoredFixture(component: component, bytes: bytes, json: json)
    }

    private static func delegatedEvaluation(preset: DelegationPreset, authority: GrantorAuthorityProvider) async throws -> TestingHTTPResponse {
        let app = try await TestApp.makeApplication()
        do {
            let keys = try await TestApp.configureTesting(app, grantorAuthority: authority)
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let component = try await ComponentFixtures.createQuestionnaireComponent(on: app.db, studyId: try study.requireId())
            let grant = try await AuthContext.$current.withValue(Self.grantor) {
                try await app.grove[DelegationService.self].create(
                    studyID: study.requireId(), clientID: "trove-draft-editor", preset: preset, expiresAt: Date().addingTimeInterval(300)
                )
            }
            let token = try await TestApp.signToken(
                keys: keys,
                subject: grant.grantor.subject,
                roles: [TestApp.researcherRole],
                groups: ["/Test Group/admin"],
                clientID: "trove-draft-editor"
            )
            let response = try await app.sendRequest(.POST, try Self.path(study, component), beforeRequest: { request in
                request.bearerAuth(token)
                request.headers.replaceOrAdd(name: "Trove-Delegation-ID", value: grant.id.uuidString)
                try Self.setBody(Components.Schemas.QuestionnaireScenarioInput(scenarios: [
                    .init(name: "Answered", item: [.init(linkId: "q1", answer: [.init(valueString: "Fine")])])
                ]), in: &request)
            })
            try await TestDatabase.shutdown(app)
            return response
        } catch {
            try? await TestDatabase.shutdown(app)
            throw error
        }
    }

    @Test
    func evaluatesTheStoredResourceWithoutChangingTheDraft() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let stored = try await Self.storedFixture("nested-all-any.json", study: study, on: app)
            let (component, bytes, json) = (stored.component, stored.bytes, stored.json)
            let input = try #require(json["request"]?.converted(to: Components.Schemas.QuestionnaireScenarioInput.self))
            let response = try await app.sendRequest(.POST, try Self.path(study, component), beforeRequest: { request in
                request.bearerAuth(token)
                try Self.setBody(input, in: &request)
            })
            try #require(response.status == .ok)
            let report = try response.content.decode(Components.Schemas.QuestionnaireScenarioReport.self)
            #expect(report.componentId == (try component.requireId()).uuidString)
            #expect(report.draftRevision == study.draftRevision.uuidString)
            #expect(report.sha256 == FHIRValidationClient.digest(bytes))
            #expect(report.evaluator == QuestionnaireScenarios.evaluator)
            let expected = try #require(json["expected"])
            let actual = ScenarioJSON.object([
                "graph": try #require(ScenarioJSON.from(report.graph)), "scenarios": try #require(ScenarioJSON.from(report.scenarios))
            ])
            let mismatches = QuestionnaireScenarioFixture.mismatches(expected: expected, actual: actual, path: "expected")
            #expect(mismatches.isEmpty, "\(mismatches)")
            let storedStudy = try #require(try await Study.find(study.requireId(), on: app.db))
            #expect(storedStudy.draftRevision == study.draftRevision)
            #expect(try await StudyPublicationCandidate.query(on: app.db).count() == 0)
        }
    }

    @Test
    func rejectsOtherComponentsDuplicateNamesAndExcessiveQuestionnaires() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let informational = try await ComponentFixtures.createInformationalComponent(on: app.db, studyId: try study.requireId())
            let questionnaire = try await ComponentFixtures.createQuestionnaireComponent(on: app.db, studyId: try study.requireId())
            let items = (0...QuestionnaireStructure.maximumItems).map { ["linkId": "q\($0)", "type": "string"] }
            let large = Component(
                studyId: try study.requireId(),
                data: .questionnaire(.init(questionnaire: String(decoding: try JSONSerialization.data(withJSONObject: [
                    "resourceType": "Questionnaire", "status": "active", "item": items
                ]), as: UTF8.self))),
                name: "Large"
            )
            try await large.create(on: app.db)
            let once = Components.Schemas.QuestionnaireScenarioInput(scenarios: [.init(name: "Unanswered", item: [])])
            let twice = Components.Schemas.QuestionnaireScenarioInput(scenarios: [.init(name: "Same", item: []), .init(name: "Same", item: [])])
            let cases = [
                Case(component: informational, input: once, status: .unprocessableEntity),
                Case(component: questionnaire, input: twice, status: .badRequest),
                Case(component: large, input: once, status: .unprocessableEntity),
                Case(component: questionnaire, input: once, status: .ok)
            ]
            for entry in cases {
                let response = try await app.sendRequest(.POST, try Self.path(study, entry.component), beforeRequest: { request in
                    request.bearerAuth(token)
                    try Self.setBody(entry.input, in: &request)
                })
                #expect(response.status == entry.status, "\(entry.component.name)")
            }
            let unknown = "\(apiBasePath)/studies/\(try study.requireId())/components/\(UUID())/scenarios"
            let response = try await app.sendRequest(.POST, unknown, beforeRequest: { request in
                request.bearerAuth(token)
                try Self.setBody(once, in: &request)
            })
            #expect(response.status == .notFound)
        }
    }

    @Test
    func enforcesTheScenarioCountAtTheHTTPBoundary() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let component = try await ComponentFixtures.createQuestionnaireComponent(on: app.db, studyId: try study.requireId())
            let scenarios = (1...21).map { Components.Schemas.QuestionnaireScenario(name: "Scenario \($0)", item: []) }
            for count in [0, 20, 21] {
                let response = try await app.sendRequest(.POST, try Self.path(study, component), beforeRequest: { request in
                    request.bearerAuth(token)
                    try Self.setBody(Components.Schemas.QuestionnaireScenarioInput(scenarios: Array(scenarios.prefix(count))), in: &request)
                })
                #expect(response.status == (count == 20 ? .ok : .badRequest))
            }
        }
    }

    @Test
    func rejectsAnOversizedBodyBeforeDecoding() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let questionnaire = try await ComponentFixtures.createQuestionnaireComponent(on: app.db, studyId: try study.requireId())
            let answer = Components.Schemas.QuestionnaireScenarioAnswer(valueString: String(repeating: "x", count: 10_000))
            let answers = Array(repeating: answer, count: 100)
            let items = Array(repeating: Components.Schemas.QuestionnaireScenarioItem(linkId: "q1", answer: answers), count: 5)
            let input = Components.Schemas.QuestionnaireScenarioInput(scenarios: [.init(name: "Large", item: items)])
            let response = try await app.sendRequest(.POST, try Self.path(study, questionnaire), beforeRequest: { request in
                request.bearerAuth(token)
                try Self.setBody(input, in: &request)
            })
            #expect(response.status == .payloadTooLarge)
        }
    }

    /// Scenario results disclose only draft content, so an inspection grant suffices.
    @Test(arguments: [DelegationPreset.inspectStudy, .editStudyDraft])
    func delegatedInspectionCanEvaluateScenarios(preset: DelegationPreset) async throws {
        #expect(KeycloakClientPolicy.draftPermission(for: Operations.EvaluateQuestionnaireScenarios.id) == .inspect)
        let response = try await Self.delegatedEvaluation(preset: preset, authority: Self.authority)
        #expect(response.status == .ok)
        let report = try response.content.decode(Components.Schemas.QuestionnaireScenarioReport.self)
        #expect(report.scenarios.map(\.complete) == [true])
        #expect(report.scenarios.first?.response.map(\.linkId) == ["q1"])
    }

    /// The scenarios are evaluated only after the grantor's live authority admits the read.
    @Test
    func withholdsScenarioReportWhenTheGrantorHasNoAuthority() async throws {
        let checks = Mutex(0)
        let authority = GrantorAuthorityProvider { actor in
            checks.withLock { $0 += 1 }
            return .init(issuer: actor.issuer, subject: actor.subject, enabled: false, roles: [TestApp.researcherRole], groups: ["/Test Group/admin"])
        }
        let response = try await Self.delegatedEvaluation(preset: .inspectStudy, authority: authority)
        #expect(checks.withLock { $0 } == 1)
        try #require(response.status == .forbidden)
        let body = try JSONDecoder().decode(ScenarioJSON.self, from: Data(response.body.readableBytesView))
        #expect(body == .object(["title": .string("Forbidden"), "status": .number(403), "detail": .string("Insufficient permissions")]))
    }
}


extension QuestionnaireScenarioIntegrationTests {
    @Test
    func repeatedAnswerEvidenceReturnsABoundedError() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let condition = ["question": "source", "operator": "=", "answerString": "yes"]
            var items: [[String: Any]] = [["linkId": "source", "type": "string"]]
            for index in 0..<100 {
                items.append(["linkId": "q\(index)", "type": "display", "enableWhen": [condition]])
            }
            let bytes = try JSONSerialization.data(withJSONObject: ["resourceType": "Questionnaire", "item": items])
            let component = Component(
                studyId: try study.requireId(), data: .questionnaire(.init(questionnaire: String(decoding: bytes, as: UTF8.self))), name: "Evidence"
            )
            try await component.create(on: app.db)
            let answer = Components.Schemas.QuestionnaireScenarioAnswer(valueString: String(repeating: "x", count: 10_000))
            let scenarios = (0..<9).map { index in
                Components.Schemas.QuestionnaireScenario(name: "scenario-\(index)", item: [.init(linkId: "source", answer: [answer])])
            }
            let response = try await app.sendRequest(.POST, try Self.path(study, component), beforeRequest: { request in
                request.bearerAuth(token)
                try Self.setBody(Components.Schemas.QuestionnaireScenarioInput(scenarios: scenarios), in: &request)
            })
            #expect(response.status == .unprocessableEntity)
            #expect(response.body.readableBytes < 1_024)
            #expect(response.body.string.contains("The report exceeds its size limit"))
            let stored = try #require(try await Study.find(study.requireId(), on: app.db))
            #expect(stored.draftRevision == study.draftRevision)
        }
    }
}
