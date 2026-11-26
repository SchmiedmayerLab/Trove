//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIServer


/// Derives a Questionnaire's branching graph and evaluates named synthetic answer sets against it, without side effects.
enum QuestionnaireScenarios {
    enum BoundExceeded: Error, Equatable {
        /// The Questionnaire has more items, conditions or nesting levels than the evaluator reads.
        case questionnaire
        /// A scenario's answers produce more item instances than the evaluator reads.
        case scenario(String)
        /// The aggregate report would exceed a request-wide limit.
        case report
    }

    /// The identity of these evaluation rules. The shared scenario fixtures name the identity they were written for.
    static let evaluator = "trove-questionnaire-scenarios-1"
    static let maximumInstances = 5_000

    static func evaluate(
        _ bytes: Data, scenarios: [Components.Schemas.QuestionnaireScenario]
    ) throws(BoundExceeded) -> (graph: Components.Schemas.QuestionnaireGraph, results: [Components.Schemas.QuestionnaireScenarioResult]) {
        guard scenarios.count <= ScenarioReportBudget.maximumScenarios else { throw .report }
        let structure: QuestionnaireStructure
        do {
            structure = try QuestionnaireStructure(bytes: bytes)
        } catch {
            throw .questionnaire
        }
        var budget = ScenarioReportBudget()
        try budget.reserveGraph(structure)
        var results: [Components.Schemas.QuestionnaireScenarioResult] = []
        for scenario in scenarios {
            results.append(try evaluate(scenario, in: structure, budget: &budget))
        }
        return (graph(of: structure), results)
    }

    static func graph(of structure: QuestionnaireStructure) -> Components.Schemas.QuestionnaireGraph {
        let items = structure.items
        let nodes = items.map { item in
            Components.Schemas.QuestionnaireGraphNode(
                path: item.path,
                linkId: item.linkId,
                _type: item.type,
                parent: item.parent.map { items[$0].path },
                text: item.text,
                enableBehavior: item.enableBehavior,
                repeats: item.repeats,
                required: item.required
            )
        }
        var edges: [Components.Schemas.QuestionnaireGraphEdge] = []
        let siblingGroups = [items.indices.filter { items[$0].parent == nil }] + items.map(\.children)
        for item in items {
            for child in item.children {
                edges.append(.init(kind: .containment, from: item.path, to: items[child].path))
            }
        }
        for siblings in siblingGroups {
            for (previous, next) in zip(siblings, siblings.dropFirst()) {
                edges.append(.init(kind: .order, from: items[previous].path, to: items[next].path))
            }
        }
        for item in items {
            for condition in item.conditions {
                guard let target = condition.target else {
                    continue
                }
                edges.append(.init(kind: .dependency, from: items[target].path, to: item.path, condition: .init(
                    index: condition.index, question: condition.question ?? "", _operator: condition.operator, answer: condition.answer
                )))
            }
        }
        return .init(
            complete: structure.diagnostics.allSatisfy { $0.severity == .information },
            nodes: nodes,
            edges: edges,
            diagnostics: structure.diagnostics
        )
    }

    private static func evaluate(
        _ scenario: Components.Schemas.QuestionnaireScenario, in structure: QuestionnaireStructure, budget: inout ScenarioReportBudget
    ) throws(BoundExceeded) -> Components.Schemas.QuestionnaireScenarioResult {
        try budget.reserveResponse(scenario)
        let form: ScenarioForm
        do {
            form = try ScenarioForm(structure: structure, items: scenario.item, limit: min(maximumInstances, budget.remainingOccurrences))
        } catch {
            throw budget.remainingOccurrences < maximumInstances ? .report : .scenario(scenario.name)
        }
        var evaluation = ScenarioEvaluation(form: form)
        try budget.reserveOccurrences(form.occurrences.count)
        try evaluation.reserveReport(in: &budget)
        let states = form.occurrences.indices.map { evaluation.state(of: $0) }
        var diagnostics = form.diagnostics
        for (index, occurrence) in form.occurrences.enumerated() where states[index].state == .disabled {
            for answer in occurrence.answers {
                let diagnostic = ValidationDiagnostic.trove(
                    "answer-excluded",
                    path: answer.path,
                    message: "The item is disabled, so a completed response does not keep this answer.",
                    severity: .information
                )
                try budget.reserveDiagnostic(diagnostic)
                diagnostics.append(diagnostic)
            }
        }
        let ordered = ValidationDiagnostic.ordered(diagnostics, limit: QuestionnaireStructure.maximumDiagnostics)
        return .init(
            name: scenario.name,
            complete: states.allSatisfy { $0.state != .notEvaluated } && ordered.allSatisfy { $0.severity != .error },
            items: states,
            response: response(form.roots, form: form, states: states),
            diagnostics: ordered
        )
    }

    /// The answers a completed response keeps: everything except disabled items, in document order.
    private static func response(
        _ occurrences: [Int], form: ScenarioForm, states: [Components.Schemas.QuestionnaireScenarioItemState]
    ) -> [Components.Schemas.QuestionnaireScenarioItem] {
        occurrences.compactMap { index in
            let occurrence = form.occurrences[index]
            let item = form.structure.items[occurrence.item]
            guard states[index].state != .disabled, let linkId = item.linkId else {
                return nil
            }
            if item.isGroup {
                let nested = response(occurrence.children, form: form, states: states)
                return nested.isEmpty ? nil : .init(linkId: linkId, item: nested)
            }
            guard !occurrence.answers.isEmpty else {
                return nil
            }
            let answers = occurrence.answers.enumerated().map { position, answer in
                var kept = answer.api
                let nested = response(occurrence.children.filter { form.occurrences[$0].answerIndex == position }, form: form, states: states)
                kept.item = nested.isEmpty ? nil : nested
                return kept
            }
            return .init(linkId: linkId, answer: answers)
        }
    }
}
