//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Testing
import TroveAPIClient
@testable import TroveCLI


struct ScenarioClientTests {
    private let study = UUID()
    private let component = UUID()
    private let delegation = UUID()

    private let input = Components.Schemas.QuestionnaireScenarioInput(scenarios: [
        .init(name: "Smokes", item: [.init(linkId: "smoker", answer: [.init(valueBoolean: true)])]),
        .init(name: "Unanswered", item: [])
    ])

    private func report(
        component: UUID? = nil, names: [String] = ["Smokes", "Unanswered"], graphComplete: Bool = true, scenarioComplete: Bool = true
    ) -> Components.Schemas.QuestionnaireScenarioReport {
        .init(
            componentId: (component ?? self.component).uuidString,
            draftRevision: UUID().uuidString,
            sha256: String(repeating: "0", count: 64),
            evaluator: "synthetic-evaluator",
            graph: .init(complete: graphComplete, nodes: [], edges: [], diagnostics: []),
            scenarios: names.map { .init(name: $0, complete: scenarioComplete, items: [], response: [], diagnostics: []) }
        )
    }

    private func client(_ transport: AuthoringTransport) throws -> AuthoringClient {
        let url = try #require(URL(string: "https://research.example/api/v0"))
        return AuthoringClient(serverURL: url, token: "synthetic-test-credential", transport: transport)
    }

    @Test
    func postsTheScenariosForTheComponent() async throws {
        let expected = report()
        let transport = try AuthoringTransport(response: expected)
        #expect(try await client(transport).evaluateScenarios(study, component: component, delegation: delegation, input: input) == expected)
        let record = try #require(await transport.records.first)
        #expect(record.request.method == .post)
        #expect(record.request.path == "/studies/\(study.uuidString)/components/\(component.uuidString)/scenarios")
        #expect(record.request.headerFields[.ifMatch] == nil)
        #expect(record.request.headerFields[try #require(HTTPField.Name("Trove-Delegation-ID"))] == delegation.uuidString)
        #expect(try JSONDecoder().decode(Components.Schemas.QuestionnaireScenarioInput.self, from: record.body) == input)
    }

    @Test
    func repeatAnswerEvidenceSurvivesClientRoundTrip() async throws {
        let path = "Questionnaire.item[2]"
        var expected = report()
        // Items under each answer of a repeating question read all of its answers.
        let condition = Components.Schemas.QuestionnaireScenarioConditionResult(
            index: 0,
            question: "pain",
            _operator: "=",
            outcome: .met,
            answers: [.init(valueBoolean: true), .init(valueBoolean: false)],
            questionInstance: []
        )
        expected.scenarios[0].items = [0, 1].map { index in
            .init(
                path: path + ".item[0]",
                linkId: "pain-site",
                instance: [.init(path: path, index: index)],
                state: .enabled,
                reason: .conditionsMet,
                conditions: [condition]
            )
        }
        let retained: [Components.Schemas.QuestionnaireScenarioAnswer] = [
            .init(valueBoolean: true, item: [.init(linkId: "pain-site", answer: [.init(valueString: "Knee")])]),
            .init(valueBoolean: false, item: [.init(linkId: "pain-site", answer: [.init(valueString: "Ankle")])])
        ]
        expected.scenarios[0].response = [.init(linkId: "pain", answer: retained)]
        let transport = try AuthoringTransport(response: expected)
        let decoded = try await client(transport).evaluateScenarios(study, component: component, delegation: nil, input: input)
        let output = try JSONEncoder().encode(decoded)
        #expect(try JSONDecoder().decode(Components.Schemas.QuestionnaireScenarioReport.self, from: output) == expected)
    }

    @Test(arguments: ["other-component", "missing-scenario", "reordered-scenarios"])
    func inconsistentReportIsRejected(change: String) async throws {
        let mismatched = switch change {
        case "other-component": report(component: UUID())
        case "missing-scenario": report(names: ["Smokes"])
        default: report(names: ["Unanswered", "Smokes"])
        }
        let transport = try AuthoringTransport(response: mismatched)
        await #expect(throws: CLIError.requestFailed) {
            try await client(transport).evaluateScenarios(study, component: component, delegation: nil, input: input)
        }
    }

    @Test
    func exitCodeReportsIncompleteAnalysis() {
        #expect(EvaluateQuestionnaireScenarios.exitCode(for: report()) == 0)
        #expect(EvaluateQuestionnaireScenarios.exitCode(for: report(graphComplete: false)) == 3)
        #expect(EvaluateQuestionnaireScenarios.exitCode(for: report(scenarioComplete: false)) == 3)
    }

    @Test
    func scenarioFileMustMatchTheSchema() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = directory.appending(path: "valid.json")
        try JSONEncoder().encode(input).write(to: valid)
        #expect(try CLIInput.decode(Components.Schemas.QuestionnaireScenarioInput.self, file: valid.path) == input)
        let invalid = directory.appending(path: "invalid.json")
        try Data(#"{"scenarios": [{"name": "Unanswered", "item": [], "extra": true}]}"#.utf8).write(to: invalid)
        #expect(throws: CLIError.invalidInput) {
            try CLIInput.decode(Components.Schemas.QuestionnaireScenarioInput.self, file: invalid.path)
        }
    }
}
