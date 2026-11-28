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


struct QuestionnaireScenarioTests {
    private static func questionnaire(_ items: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["resourceType": "Questionnaire", "status": "active", "item": items])
    }

    @Test(arguments: try QuestionnaireScenarioFixture.all())
    func sharedFixtureMatches(_ fixture: QuestionnaireScenarioFixture) throws {
        let json = try fixture.json()
        #expect(json["evaluator"] == .string(QuestionnaireScenarios.evaluator))
        let expected = try #require(json["expected"])
        let mismatches = QuestionnaireScenarioFixture.mismatches(expected: expected, actual: try fixture.evaluate(), path: "expected")
        #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
    }

    @Test
    func everySharedFixtureIsEvaluated() throws {
        #expect(try QuestionnaireScenarioFixture.all().count == 10)
    }

    /// Translations change labels, not logic: the bilingual fixtures have the same complete graph in every language.
    @Test(arguments: try MultilingualQuestionnaireFixture.all())
    func translationsDoNotChangeTheGraph(_ fixture: MultilingualQuestionnaireFixture) throws {
        let (graph, results) = try QuestionnaireScenarios.evaluate(try fixture.bytes(), scenarios: [.init(name: "empty", item: [])])
        #expect(graph.complete, "\(graph.diagnostics)")
        #expect(!graph.nodes.isEmpty)
        #expect(results.map(\.complete) == [true])
    }

    @Test(arguments: ["", "[]", #"{"resourceType": "Patient"}"#])
    func unreadableResourceHasAnIncompleteEmptyGraph(_ text: String) throws {
        let scenario = Components.Schemas.QuestionnaireScenario(name: "answers", item: [.init(linkId: "q1", answer: [.init(valueBoolean: true)])])
        let (graph, results) = try QuestionnaireScenarios.evaluate(Data(text.utf8), scenarios: [scenario])
        #expect(!graph.complete)
        #expect(graph.nodes.isEmpty && graph.edges.isEmpty)
        #expect(graph.diagnostics.map(\.rule) == ["fhir-structure"])
        #expect(results.first?.complete == false)
        #expect(results.first?.diagnostics.map(\.rule) == ["answer-item"])
    }

    @Test
    func malformedEnablementKeepsItemsUnevaluated() throws {
        let bytes = try Self.questionnaire([
            ["linkId": "question", "type": "boolean"],
            ["linkId": "bad-list", "type": "string", "enableWhen": ["question": "question"]],
            ["linkId": "bad-behavior", "type": "string", "enableBehavior": true]
        ])
        let (graph, results) = try QuestionnaireScenarios.evaluate(bytes, scenarios: [.init(name: "empty", item: [])])
        #expect(!graph.complete)
        #expect(Set(graph.diagnostics.map(\.rule)) == ["enable-when-value", "enable-behavior-value"])
        let result = try #require(results.first)
        #expect(!result.complete)
        #expect(result.items.map(\.state) == [.enabled, .notEvaluated, .notEvaluated])
    }

    @Test(arguments: [false, true])
    func existenceOfDisabledCalculatedAnswer(enabled: Bool) throws {
        let expression: [String: Any] = [
            "url": QuestionnaireStructure.calculatedExpressionURL,
            "valueExpression": ["language": "text/fhirpath", "expression": "1"]
        ]
        let bytes = try Self.questionnaire([
            ["linkId": "flag", "type": "boolean"],
            [
                "linkId": "group", "type": "group",
                "enableWhen": [["question": "flag", "operator": "=", "answerBoolean": true]],
                "item": [["linkId": "score", "type": "integer", "extension": [expression]]]
            ],
            ["linkId": "absent", "type": "display", "enableWhen": [["question": "score", "operator": "exists", "answerBoolean": false]]]
        ])
        let scenario = Components.Schemas.QuestionnaireScenario(name: "check", item: [.init(linkId: "flag", answer: [.init(valueBoolean: enabled)])])
        let (_, results) = try QuestionnaireScenarios.evaluate(bytes, scenarios: [scenario])
        let dependent = try #require(results.first?.items.last)
        let condition = try #require(dependent.conditions.first)
        #expect(dependent.state == (enabled ? .notEvaluated : .enabled))
        #expect(condition.outcome == (enabled ? .notEvaluated : .met))
        #expect(condition.answers.isEmpty)
    }

    @Test
    func referenceConditionNeedsAReference() throws {
        let bytes = try Self.questionnaire([
            ["linkId": "source", "type": "reference"],
            ["linkId": "gated", "type": "display", "enableWhen": [["question": "source", "operator": "=", "answerReference": ["display": "Clinic"]]]]
        ])
        let graph = try QuestionnaireScenarios.evaluate(bytes, scenarios: []).graph
        #expect(graph.diagnostics.map(\.rule) == ["enable-when-answer"])
        #expect(graph.diagnostics.map(\.path) == ["Questionnaire.item[1].enableWhen[0].answerReference"])
    }

    @Test
    func conditionLimitBelongsToTheQuestionnaire() throws {
        let condition = ["question": "q0", "operator": "exists", "answerBoolean": true] as [String: Any]
        let gated = (1...201).map { index in
            ["linkId": "g\(index)", "type": "display", "enableBehavior": "any", "enableWhen": Array(repeating: condition, count: 100)] as [String: Any]
        }
        #expect(throws: QuestionnaireScenarios.BoundExceeded.questionnaire) {
            try QuestionnaireScenarios.evaluate(try Self.questionnaire([["linkId": "q0", "type": "boolean"]] + gated), scenarios: [])
        }
    }

    /// The longest dependency chain the item limit admits evaluates on a concurrency thread's stack.
    @Test
    func longestDependencyChainEvaluatesInATask() async throws {
        let chain = (0..<QuestionnaireStructure.maximumItems).map { index -> [String: Any] in
            var item: [String: Any] = ["linkId": "q\(index)", "type": "boolean"]
            if index > 0 {
                item["enableWhen"] = [["question": "q\(index - 1)", "operator": "=", "answerBoolean": true]]
            }
            return item
        }
        let bytes = try Self.questionnaire(chain)
        let answers = (0..<QuestionnaireStructure.maximumItems).map {
            Components.Schemas.QuestionnaireScenarioItem(linkId: "q\($0)", answer: [.init(valueBoolean: true)])
        }
        let states = try await Task.detached {
            try QuestionnaireScenarios.evaluate(bytes, scenarios: [.init(name: "chain", item: answers)]).results[0].items.map(\.state)
        }.value
        #expect(states == Array(repeating: .enabled, count: QuestionnaireStructure.maximumItems))
    }

    @Test
    func questionnaireBoundsAreEnforced() throws {
        let wide = try Self.questionnaire((0...QuestionnaireStructure.maximumItems).map { ["linkId": "q\($0)", "type": "string"] })
        #expect(throws: QuestionnaireScenarios.BoundExceeded.questionnaire) {
            try QuestionnaireScenarios.evaluate(wide, scenarios: [])
        }
        var deep: [String: Any] = ["linkId": "leaf", "type": "string"]
        for level in 0..<QuestionnaireStructure.maximumDepth {
            deep = ["linkId": "g\(level)", "type": "group", "item": [deep]]
        }
        #expect(throws: QuestionnaireScenarios.BoundExceeded.questionnaire) {
            try QuestionnaireScenarios.evaluate(try Self.questionnaire([deep]), scenarios: [])
        }
        let limit = try Self.questionnaire((1..<QuestionnaireStructure.maximumItems).map { ["linkId": "q\($0)", "type": "string"] })
        #expect(try QuestionnaireScenarios.evaluate(limit, scenarios: []).graph.complete)
    }

    @Test
    func scenarioInstanceBoundIsEnforced() throws {
        let group: [String: Any] = ["linkId": "group", "type": "group", "repeats": true, "item": (0..<10).map { ["linkId": "q\($0)", "type": "string"] }]
        let bytes = try Self.questionnaire([group])
        let instances = QuestionnaireScenarios.maximumInstances / 11 + 1
        let scenario = Components.Schemas.QuestionnaireScenario(name: "many", item: Array(repeating: .init(linkId: "group"), count: instances))
        #expect(throws: QuestionnaireScenarios.BoundExceeded.scenario("many")) {
            try QuestionnaireScenarios.evaluate(bytes, scenarios: [.init(name: "few", item: []), scenario])
        }
    }

    @Test
    func resultsFollowRequestOrderAndRepeatExactly() throws {
        let fixture = try #require(try QuestionnaireScenarioFixture.all().first { $0.file == "nested-all-any.json" })
        let first = try fixture.evaluate()
        #expect(try fixture.evaluate() == first)
        #expect(first["scenarios"]?.array?.compactMap { $0["name"]?.string } == ["cough and rash, mild", "fever, severe", "only cough, severe"])
    }
}
