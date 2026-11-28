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


struct ScenarioReportBudgetTests {
    private typealias Scenario = Components.Schemas.QuestionnaireScenario

    private static func questionnaire(_ items: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["resourceType": "Questionnaire", "item": items])
    }

    @Test
    func scenarioAndOccurrenceLimitsApplyAcrossTheRequest() throws {
        let scenarios = (0..<ScenarioReportBudget.maximumScenarios).map { Scenario(name: "scenario-\($0)", item: []) }
        // The largest questionnaire, with one repeating group, in the largest number of empty scenarios.
        var items: [[String: Any]] = (0..<(QuestionnaireStructure.maximumItems - 2)).map { ["linkId": "q\($0)", "type": "string"] }
        items.append(["linkId": "group", "type": "group", "repeats": true, "item": [["linkId": "member", "type": "string"]]])
        let bytes = try Self.questionnaire(items)
        let results = try QuestionnaireScenarios.evaluate(bytes, scenarios: scenarios).results
        #expect(results.reduce(0) { $0 + $1.items.count } == ScenarioReportBudget.maximumOccurrences)
        #expect(throws: QuestionnaireScenarios.BoundExceeded.report) {
            try QuestionnaireScenarios.evaluate(bytes, scenarios: scenarios + [.init(name: "extra", item: [])])
        }
        // A second group instance in one scenario adds two occurrences beyond the request limit.
        var repeated = scenarios
        repeated[0] = Scenario(name: "scenario-0", item: [.init(linkId: "group"), .init(linkId: "group")])
        #expect(throws: QuestionnaireScenarios.BoundExceeded.report) {
            try QuestionnaireScenarios.evaluate(bytes, scenarios: repeated)
        }
    }

    @Test
    func conditionResultsIncludeEveryScenarioAndOccurrence() throws {
        let condition = ["question": "source", "operator": "=", "answerString": "yes"]
        let conditions = Array(repeating: condition, count: 100)
        let child: [String: Any] = ["linkId": "child", "type": "display", "enableBehavior": "any", "enableWhen": conditions]
        let group: [String: Any] = ["linkId": "group", "type": "group", "repeats": true, "item": [child]]
        let bytes = try Self.questionnaire([["linkId": "source", "type": "string"], group])
        let groups = Array(repeating: Components.Schemas.QuestionnaireScenarioItem(linkId: "group"), count: 100)
        let scenarios = ["first", "second"].map { Scenario(name: $0, item: groups) }
        let results = try QuestionnaireScenarios.evaluate(bytes, scenarios: scenarios).results
        let count = results.flatMap(\.items).reduce(0) { $0 + $1.conditions.count }
        #expect(count == ScenarioReportBudget.maximumConditions)
        #expect(throws: QuestionnaireScenarios.BoundExceeded.report) {
            try QuestionnaireScenarios.evaluate(bytes, scenarios: scenarios + [.init(name: "extra", item: [])])
        }
    }

    @Test
    func repeatedEvidenceIsChargedEvenWhenItsStringsShareStorage() throws {
        let condition = ["question": "source", "operator": "=", "answerString": "yes"]
        let target: [String: Any] = [
            "linkId": "target", "type": "display", "enableBehavior": "any", "enableWhen": Array(repeating: condition, count: 100)
        ]
        let bytes = try Self.questionnaire([["linkId": "source", "type": "string"], target])
        let answer = Components.Schemas.QuestionnaireScenarioAnswer(valueString: String(repeating: "x", count: 10_000))
        let scenarios = (0..<9).map { Scenario(name: "s\($0)", item: [.init(linkId: "source", answer: [answer])]) }
        let accepted = try QuestionnaireScenarios.evaluate(bytes, scenarios: Array(scenarios.prefix(8)))
        #expect(accepted.results.last?.items.last?.conditions.last?.answers == [answer])
        #expect(throws: QuestionnaireScenarios.BoundExceeded.report) {
            try QuestionnaireScenarios.evaluate(bytes, scenarios: scenarios)
        }
    }

    @Test
    func repeatedNumericEvidenceIsLimitedIndependentlyOfText() throws {
        let condition: [String: Any] = ["question": "source", "operator": "=", "answerInteger": 1]
        let target: [String: Any] = [
            "linkId": "target", "type": "display", "enableBehavior": "any", "enableWhen": Array(repeating: condition, count: 100)
        ]
        let bytes = try Self.questionnaire([["linkId": "source", "type": "integer", "repeats": true], target])
        let answers = (0..<100).map { Components.Schemas.QuestionnaireScenarioAnswer(valueInteger: $0) }
        let scenarios = (0..<5).map { Scenario(name: "s\($0)", item: [.init(linkId: "source", answer: answers)]) }
        let accepted = try QuestionnaireScenarios.evaluate(bytes, scenarios: Array(scenarios.prefix(4)))
        #expect(accepted.results.last?.items.last?.conditions.last?.answers == answers)
        #expect(throws: QuestionnaireScenarios.BoundExceeded.report) {
            try QuestionnaireScenarios.evaluate(bytes, scenarios: scenarios)
        }
    }

    @Test
    func evidenceCardinalityAndNestedTextAcceptTheLastUnit() throws {
        var budget = ScenarioReportBudget()
        let scalar = Components.Schemas.QuestionnaireScenarioAnswer(valueBoolean: false)
        for _ in 0..<ScenarioReportBudget.maximumAnswers {
            try budget.reserveAnswer(scalar)
        }
        #expect(throws: QuestionnaireScenarios.BoundExceeded.report) { try budget.reserveAnswer(scalar) }

        budget = ScenarioReportBudget()
        let display = String(repeating: "é", count: 4_096)
        let coding = Components.Schemas.QuestionnaireScenarioAnswer(valueCoding: .init(display: display))
        for _ in 0..<(ScenarioReportBudget.maximumTextBytes / display.utf8.count) {
            try budget.reserveAnswer(coding)
        }
        #expect(throws: QuestionnaireScenarios.BoundExceeded.report) { try budget.reserveText("x") }
    }
}
