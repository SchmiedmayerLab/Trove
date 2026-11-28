//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIServer


/// Strongly connected components of a dependency graph, keeping those that form a cycle.
private struct TarjanCycles {
    let dependencies: [[Int]]
    private var order: [Int?]
    private var lowLink: [Int]
    private var onStack: [Bool]
    private var stack: [Int] = []
    private var counter = 0
    private var components: [[Int]] = []

    init(dependencies: [[Int]]) {
        self.dependencies = dependencies
        order = Array(repeating: nil, count: dependencies.count)
        lowLink = Array(repeating: 0, count: dependencies.count)
        onStack = Array(repeating: false, count: dependencies.count)
    }

    mutating func cyclicComponents() -> [[Int]] {
        for node in dependencies.indices where order[node] == nil {
            visit(node)
        }
        return components
    }

    private mutating func visit(_ node: Int) {
        order[node] = counter
        lowLink[node] = counter
        counter += 1
        stack.append(node)
        onStack[node] = true
        for next in dependencies[node] {
            if let nextOrder = order[next] {
                if onStack[next] {
                    lowLink[node] = min(lowLink[node], nextOrder)
                }
            } else {
                visit(next)
                lowLink[node] = min(lowLink[node], lowLink[next])
            }
        }
        guard lowLink[node] == order[node] else {
            return
        }
        var component: [Int] = []
        while let member = stack.popLast() {
            onStack[member] = false
            component.append(member)
            if member == node {
                break
            }
        }
        if component.count > 1 || dependencies[node].contains(node) {
            components.append(component)
        }
    }
}


extension QuestionnaireStructure {
    static let operators: Set<String> = ["exists", "=", "!=", ">", "<", ">=", "<="]
    static let orderedKinds: Set<String> = ["Decimal", "Integer", "Date", "DateTime", "Time", "Quantity"]
    private static let optionKinds: Set<String> = ["Coding", "String", "Integer", "Date", "Time", "Reference"]

    /// The `value[x]` types an answer to each answerable item type may have.
    static let answerKinds: [String: Set<String>] = [
        "boolean": ["Boolean"], "decimal": ["Decimal"], "integer": ["Integer"], "date": ["Date"], "dateTime": ["DateTime"],
        "time": ["Time"], "string": ["String"], "text": ["String"], "url": ["Uri"], "choice": optionKinds,
        "open-choice": optionKinds, "attachment": ["Attachment"], "reference": ["Reference"], "quantity": ["Quantity"]
    ]

    /// The `answer[x]` types a condition other than `exists` may compare with each answerable item type.
    static let conditionKinds: [String: Set<String>] = [
        "boolean": ["Boolean"], "decimal": ["Decimal", "Integer"], "integer": ["Decimal", "Integer"], "date": ["Date"],
        "dateTime": ["DateTime"], "time": ["Time"], "string": ["String"], "text": ["String"], "url": [], "choice": optionKinds,
        "open-choice": optionKinds, "attachment": [], "reference": ["Reference"], "quantity": ["Quantity"]
    ]

    private static func apiAnswer(kind: String, json: ScenarioJSON) -> Components.Schemas.QuestionnaireScenarioAnswer? {
        let members: [String: Set<String>] = [
            "Coding": ["system", "version", "code", "display"], "Quantity": ["value", "comparator", "unit", "system", "code"],
            "Reference": ["reference", "display"], "Attachment": ["contentType", "url", "title"]
        ]
        let value = members[kind].map { allowed in ScenarioJSON.object((json.object ?? [:]).filter { allowed.contains($0.key) }) } ?? json
        return ScenarioJSON.object(["value\(kind)": value]).converted(to: Components.Schemas.QuestionnaireScenarioAnswer.self)
    }

    /// Reads an item's `enableWhen` and `enableBehavior` and reports each condition that cannot be evaluated.
    mutating func readConditions(of index: Int) -> [ValidationDiagnostic] {
        let item = items[index]
        let object = itemJSON[index]
        var found: [ValidationDiagnostic] = []
        let rawConditions = object["enableWhen"]
        if rawConditions != nil && rawConditions?.array == nil {
            items[index].invalidEnablement = true
            found.append(.trove("enable-when-value", path: "\(item.path).enableWhen", message: "enableWhen must be an array of conditions."))
        }
        let entries = rawConditions?.array ?? []
        for (position, entry) in entries.enumerated() {
            let (condition, findings) = readCondition(entry, position: position, path: "\(item.path).enableWhen[\(position)]", of: index)
            items[index].conditions.append(condition)
            found += findings
        }
        if object["enableBehavior"] != nil && item.enableBehavior != "all" && item.enableBehavior != "any" {
            items[index].invalidEnablement = true
            found.append(.trove("enable-behavior-value", path: "\(item.path).enableBehavior", message: "enableBehavior must be all or any."))
        } else if item.enableBehavior == nil && entries.count > 1 {
            items[index].invalidEnablement = true
            found.append(.trove(
                "enable-behavior-required",
                path: "\(item.path).enableBehavior",
                message: "An item with several conditions must state enableBehavior.",
                nextAction: "Set enableBehavior to all or any."
            ))
        }
        if !entries.isEmpty && item.enableExpression {
            found.append(.trove(
                "enable-when-expression-conflict",
                path: item.path,
                message: "An item uses either enableWhen or an enableWhenExpression, not both."
            ))
        }
        return found
    }

    private func readCondition(
        _ entry: ScenarioJSON, position: Int, path: String, of index: Int
    ) -> (condition: Condition, findings: [ValidationDiagnostic]) {
        let object = entry.object ?? [:]
        let question = object["question"]?.string
        let operation = object["operator"]?.string
        let answers = object.filter { $0.key.hasPrefix("answer") }
        let kind = answers.count == 1 ? answers.first.map { String($0.key.dropFirst("answer".count)) } : nil
        let expected = kind.flatMap { kind in answers.first.flatMap { ScenarioValue.parse(kind: kind, json: $0.value) } }
        let target = question.flatMap(item(linkId:))
        var findings: [ValidationDiagnostic] = []
        func fail(_ rule: String, _ element: String, _ message: String) {
            findings.append(.trove(rule, path: element.isEmpty ? path : "\(path).\(element)", message: message))
        }
        if let question, target == nil {
            fail("enable-when-question", "question", duplicateLinkIds.contains(question)
                 ? "The condition names linkId '\(question)', which several items use."
                 : "The condition names linkId '\(question)', which no item uses.")
        } else if question == nil {
            fail("enable-when-question", "question", "The condition names no question.")
        } else if let target, !items[target].isAnswerable {
            fail("enable-when-not-answerable", "question", "The condition names an item that has no answers.")
        }
        if let operation, !Self.operators.contains(operation) {
            fail("enable-when-operator", "operator", "The operator '\(operation)' is not a FHIR R4 enableWhen operator.")
        } else if operation == nil {
            fail("enable-when-operator", "operator", "The condition has no operator.")
        }
        if expected == nil {
            fail("enable-when-answer", "", "The condition needs exactly one answer value of a FHIR R4 answer type.")
        }
        if let expected, let operation, Self.operators.contains(operation) {
            findings += checkTypes(expected, operation: operation, target: target, path: path)
        }
        let answer = kind.flatMap { kind in answers.first.flatMap { Self.apiAnswer(kind: kind, json: $0.value) } }
        let condition = Condition(
            index: position,
            path: path,
            question: question,
            operator: operation,
            expected: expected,
            answer: answer,
            target: target,
            isValid: findings.isEmpty && target != nil
        )
        var notes: [ValidationDiagnostic] = []
        if case .coding(nil, _) = expected {
            notes.append(Self.missingSystem(at: "\(path).answerCoding"))
        }
        return (condition, findings + notes + repeatContext(of: index, target: target, path: path))
    }

    private func checkTypes(_ expected: ScenarioValue, operation: String, target: Int?, path: String) -> [ValidationDiagnostic] {
        var findings: [ValidationDiagnostic] = []
        let type = target.flatMap { items[$0].type }
        if operation == "exists" {
            if expected.kind != "Boolean" {
                findings.append(.trove("enable-when-type", path: path, message: "An exists condition compares with answerBoolean."))
            }
            return findings
        }
        if let type, let kinds = Self.conditionKinds[type], !kinds.contains(expected.kind) {
            findings.append(.trove(
                "enable-when-type", path: path, message: "answer\(expected.kind) cannot be compared with the answers of a \(type) item."
            ))
        }
        if !["=", "!="].contains(operation) && !Self.orderedKinds.contains(expected.kind) {
            findings.append(.trove(
                "enable-when-operator-type", path: "\(path).operator", message: "answer\(expected.kind) values have no order for '\(operation)'."
            ))
        }
        switch expected {
        case .coding(_, nil):
            findings.append(.trove("enable-when-answer", path: "\(path).answerCoding", message: "The coding needs a code."))
        case .reference(nil):
            findings.append(.trove("enable-when-answer", path: "\(path).answerReference", message: "The reference needs a reference."))
        case .quantity(let quantity) where quantity.value == nil || quantity.comparator != nil:
            findings.append(.trove(
                "enable-when-answer", path: "\(path).answerQuantity", message: "The quantity needs a value and no comparator."
            ))
        default:
            break
        }
        return findings
    }

    /// A warning when the condition can read another instance of its question: the question repeats outside the gated item's repeat
    /// context, or it follows the gated item inside a repeating context.
    private func repeatContext(of index: Int, target: Int?, path: String) -> [ValidationDiagnostic] {
        guard let target, target != index, !ancestors(of: index).contains(target), !ancestors(of: target).contains(index) else {
            return []
        }
        let shared = Set(ancestors(of: index) + [index])
        let repeating = { (item: Int) in items[item].formsInstances && items[item].repeats }
        let message: String
        if ancestors(of: target).prefix(while: { !shared.contains($0) }).contains(where: repeating) {
            message = "The question repeats outside the gated item's repeat context, so document order decides: the nearest "
                + "preceding occurrence, otherwise the nearest following one."
        } else if target > index, ancestors(of: target).contains(where: { shared.contains($0) && repeating($0) }) {
            // Items are stored in document order, so a larger index follows the gated item.
            message = "The question follows the gated item inside a repeating context, so every instance after the first reads "
                + "the preceding instance's occurrence of the question."
        } else {
            return []
        }
        return [.trove("repeat-context", path: "\(path).question", message: message, severity: .warning)]
    }
}


extension QuestionnaireStructure {
    /// Marks every item whose enablement depends on itself, through conditions or enclosing items, and reports each cycle once.
    mutating func markCycles() -> [ValidationDiagnostic] {
        // Invalid conditions are never evaluated, so they cannot close a cycle.
        var cycles = TarjanCycles(dependencies: items.map { item in
            item.conditions.filter(\.isValid).compactMap(\.target) + (item.parent.map { [$0] } ?? [])
        })
        var found: [ValidationDiagnostic] = []
        for component in cycles.cyclicComponents() {
            let members = component.sorted()
            for member in members {
                items[member].cyclic = true
            }
            let names = members.map { "'\(items[$0].linkId ?? items[$0].path)'" }.joined(separator: ", ")
            found.append(.trove(
                "dependency-cycle",
                path: items[members[0]].path,
                message: "Items \(names) depend on their own state through their conditions or enclosing items."
            ))
        }
        return found.sorted { ($0.path, $0.message) < ($1.path, $1.message) }
    }
}
