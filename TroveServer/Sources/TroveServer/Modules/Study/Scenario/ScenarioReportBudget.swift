//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import TroveAPIServer


/// A reservation for one report, shared by the graph and every scenario. Text is measured in
/// unescaped UTF-8 bytes at every use; the separate cardinality limits bound JSON framing.
struct ScenarioReportBudget {
    typealias BoundExceeded = QuestionnaireScenarios.BoundExceeded

    static let maximumScenarios = 20
    /// Every scenario holds an instance of each item, so the largest questionnaire fits in every allowed scenario.
    static let maximumOccurrences = QuestionnaireStructure.maximumItems * maximumScenarios
    static let maximumConditions = 20_000
    static let maximumAnswers = 50_000
    static let maximumTextBytes = 8 * 1024 * 1024

    private(set) var remainingOccurrences = maximumOccurrences
    private var remainingConditions = maximumConditions
    private var remainingAnswers = maximumAnswers
    private var remainingTextBytes = maximumTextBytes

    mutating func reserveOccurrences(_ count: Int) throws(BoundExceeded) {
        guard count <= remainingOccurrences else { throw .report }
        remainingOccurrences -= count
    }

    mutating func reserveConditions(_ count: Int) throws(BoundExceeded) {
        guard count <= remainingConditions else { throw .report }
        remainingConditions -= count
    }

    mutating func reserveText(_ fields: String?...) throws(BoundExceeded) {
        for field in fields {
            let bytes = field?.utf8.count ?? 0
            guard bytes <= remainingTextBytes else { throw .report }
            remainingTextBytes -= bytes
        }
    }

    mutating func reserveAnswer(_ answer: Components.Schemas.QuestionnaireScenarioAnswer) throws(BoundExceeded) {
        guard remainingAnswers > 0 else { throw .report }
        remainingAnswers -= 1
        for (field, _) in answer.boundedTextFields {
            try reserveText(field)
        }
        try reserveText(answer.valueQuantity?.comparator?.rawValue)
    }

    /// Each submitted answer may be retained in the response. Reserve it before the form reads its value.
    mutating func reserveResponse(_ scenario: Components.Schemas.QuestionnaireScenario) throws(BoundExceeded) {
        try reserveText(scenario.name)
        var pending = [scenario.item]
        while let items = pending.popLast() {
            for item in items {
                if let children = item.item { pending.append(children) }
                for answer in item.answer ?? [] {
                    try reserveAnswer(answer)
                    if let children = answer.item { pending.append(children) }
                }
            }
        }
    }

    mutating func reserveDiagnostic(_ diagnostic: ValidationDiagnostic) throws(BoundExceeded) {
        try reserveText(diagnostic.rule, diagnostic.path, diagnostic.message, diagnostic.nextAction)
    }

    mutating func reserveGraph(_ structure: QuestionnaireStructure) throws(BoundExceeded) {
        for diagnostic in structure.diagnostics { try reserveDiagnostic(diagnostic) }
        for item in structure.items {
            try reserveText(item.path, item.linkId, item.type, item.text, item.enableBehavior)
            if let parent = item.parent {
                let path = structure.items[parent].path
                try reserveText(path, path, item.path) // Node parent and containment edge.
            }
            // An item is an endpoint of at most two sibling order edges.
            try reserveText(item.path, item.path)
            for condition in item.conditions {
                guard let target = condition.target else { continue }
                try reserveText(structure.items[target].path, item.path, condition.question, condition.operator)
                if let answer = condition.answer { try reserveAnswer(answer) }
            }
        }
    }
}
