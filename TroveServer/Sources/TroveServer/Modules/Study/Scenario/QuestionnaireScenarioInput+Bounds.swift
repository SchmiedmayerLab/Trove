//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import TroveAPIServer


extension Components.Schemas.QuestionnaireScenarioInput {
    /// Validate the decoded request before evaluating any of its synthetic answer sets.
    func validateBounds() throws {
        guard (1...ScenarioReportBudget.maximumScenarios).contains(scenarios.count) else {
            throw ServerError.badRequest("Provide between 1 and \(ScenarioReportBudget.maximumScenarios) scenarios")
        }
        guard Set(scenarios.map(\.name)).count == scenarios.count else {
            throw ServerError.badRequest("Scenario names must be unique")
        }
        for scenario in scenarios {
            guard (1...200).contains(scenario.name.unicodeScalars.count) else {
                throw ServerError.badRequest("Scenario names must contain between 1 and 200 characters")
            }
            try validateItems(scenario.item)
        }
    }

    private func validateItems(_ roots: [Components.Schemas.QuestionnaireScenarioItem]) throws {
        var groups = [roots]
        while let items = groups.popLast() {
            guard items.count <= 512 else { throw ServerError.badRequest("A scenario item list exceeds 512 entries") }
            for item in items {
                guard item.linkId.unicodeScalars.count <= 255, (item.answer?.count ?? 0) <= 100 else {
                    throw ServerError.badRequest("A scenario item exceeds the linkId or answer limit")
                }
                if let nested = item.item { groups.append(nested) }
                for answer in item.answer ?? [] {
                    try answer.validateFieldLengths()
                    if let nested = answer.item { groups.append(nested) }
                }
            }
        }
    }
}


extension Components.Schemas.QuestionnaireScenarioAnswer {
    var boundedTextFields: [(String?, Int)] {
        [
            (valueDate, 10), (valueDateTime, 40), (valueTime, 20), (valueString, 10_000), (valueUri, 2_000),
            (valueCoding?.system, 2_000), (valueCoding?.version, 200), (valueCoding?.code, 1_000), (valueCoding?.display, 10_000),
            (valueQuantity?.unit, 200), (valueQuantity?.system, 2_000), (valueQuantity?.code, 200),
            (valueReference?.reference, 2_000), (valueReference?.display, 10_000),
            (valueAttachment?.contentType, 200), (valueAttachment?.url, 2_000), (valueAttachment?.title, 1_000)
        ]
    }

    fileprivate func validateFieldLengths() throws {
        guard boundedTextFields.allSatisfy({ ($0.0?.unicodeScalars.count ?? 0) <= $0.1 }) else {
            throw ServerError.badRequest("A scenario answer exceeds its field length limit")
        }
    }
}
