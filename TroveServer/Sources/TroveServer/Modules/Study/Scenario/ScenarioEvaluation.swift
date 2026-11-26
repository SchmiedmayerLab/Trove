//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIServer


/// The FHIR R4 enablement of every item instance in one scenario form, with three-valued logic for what is not evaluated.
struct ScenarioEvaluation {
    typealias ItemState = Components.Schemas.QuestionnaireScenarioItemState
    typealias ConditionResult = Components.Schemas.QuestionnaireScenarioConditionResult

    /// A truth value that may be unknown.
    enum Truth {
        case met
        case notMet
        case unknown

        init(_ value: Bool) {
            self = value ? .met : .notMet
        }

        static func any(_ values: some Sequence<Self>) -> Self {
            var result = Self.notMet
            for value in values {
                if value == .met {
                    return .met
                }
                if value == .unknown {
                    result = .unknown
                }
            }
            return result
        }

        static func all(_ values: some Sequence<Self>) -> Self {
            var result = Self.met
            for value in values {
                if value == .notMet {
                    return .notMet
                }
                if value == .unknown {
                    result = .unknown
                }
            }
            return result
        }
    }

    let form: ScenarioForm
    private var states: [ItemState?]

    private var structure: QuestionnaireStructure {
        form.structure
    }

    init(form: ScenarioForm) {
        self.form = form
        states = Array(repeating: nil, count: form.occurrences.count)
    }

    /// Every operator except `exists` holds when at least one answer satisfies it. R4's operator code system reads "at least no
    /// answer" for `!=` and the ordered operators; R5 corrects the ordered operators to "at least one answer" and states `!=` as
    /// "no answer has a value that is equal". This evaluator reads `!=` as "at least one answer differs", as the pinned Grove
    /// questionnaire runtime does, so the preview matches what participants are shown.
    static func test(_ operation: String, expected: ScenarioValue, answers: [ScenarioValue]) -> Truth {
        switch operation {
        case "exists":
            guard case .boolean(let value) = expected else {
                return .unknown
            }
            return Truth(answers.isEmpty != value)
        case "=":
            return Truth.any(answers.map { Self.truth($0.equals(expected)) })
        case "!=":
            return Truth.any(answers.map { answer in Self.truth(answer.equals(expected).map { !$0 }) })
        default:
            return Truth.any(answers.map { answer in
                switch answer.order(comparedTo: expected) {
                case .ordered(let result): Truth(Self.satisfies(result, operation))
                case .unknown: .unknown
                case .incomparable: .notMet
                }
            })
        }
    }

    private static func truth(_ value: Bool?) -> Truth { // swiftlint:disable:this discouraged_optional_boolean
        value.map(Truth.init) ?? .unknown
    }

    private static func satisfies(_ result: ComparisonResult, _ operation: String) -> Bool {
        switch operation {
        case ">": result == .orderedDescending
        case "<": result == .orderedAscending
        case ">=": result != .orderedAscending
        default: result != .orderedDescending
        }
    }

    private static func notEvaluated(_ condition: QuestionnaireStructure.Condition) -> ConditionResult {
        ConditionResult(index: condition.index, question: condition.question, _operator: condition.operator, outcome: .notEvaluated, answers: [])
    }

    /// The state of the instance; an enclosing item is evaluated first.
    mutating func state(of occurrence: Int) -> ItemState {
        if let state = states[occurrence] {
            return state
        }
        let entry = form.occurrences[occurrence]
        let item = structure.items[entry.item]
        let parent = entry.parent.map { state(of: $0).state } ?? .enabled
        let conditions = item.cyclic
            ? item.conditions.map { Self.notEvaluated($0) }
            : item.conditions.map { evaluate($0, for: occurrence) }
        let (own, ownReason) = ownTruth(of: item, conditions: conditions)
        let (resolved, reason): (ItemState.StatePayload, ItemState.ReasonPayload) = switch (parent, own) {
        case (.disabled, _): (.disabled, .ancestorDisabled)
        case (_, .notMet): (.disabled, .conditionsNotMet)
        case (_, .unknown): (.notEvaluated, ownReason)
        case (.notEvaluated, .met): (.notEvaluated, .ancestorNotEvaluated)
        case (.enabled, .met): (.enabled, ownReason)
        }
        let result = ItemState(
            path: item.path, linkId: item.linkId, instance: entry.instance, state: resolved, reason: reason, conditions: conditions
        )
        states[occurrence] = result
        return result
    }

    private func ownTruth(of item: QuestionnaireStructure.Item, conditions: [ConditionResult]) -> (Truth, ItemState.ReasonPayload) {
        if item.cyclic {
            return (.unknown, .dependencyCycle)
        }
        if item.enableExpression {
            return (.unknown, .expressionNotEvaluated)
        }
        if item.invalidEnablement {
            return (.unknown, .conditionNotEvaluated)
        }
        if conditions.isEmpty {
            return (.met, .unconditional)
        }
        let outcomes = conditions.map { result -> Truth in
            switch result.outcome {
            case .met: .met
            case .notMet: .notMet
            case .notEvaluated: .unknown
            }
        }
        return switch item.enableBehavior == "any" ? Truth.any(outcomes) : Truth.all(outcomes) {
        case .met: (.met, .conditionsMet)
        case .notMet: (.notMet, .conditionsNotMet)
        case .unknown: (.unknown, .conditionNotEvaluated)
        }
    }

    private mutating func evaluate(_ condition: QuestionnaireStructure.Condition, for occurrence: Int) -> ConditionResult {
        guard condition.isValid, let target = condition.target, let expected = condition.expected, let operation = condition.operator,
              let source = resolve(target, from: occurrence) else {
            return Self.notEvaluated(condition)
        }
        let answers = sourceAnswers(source, for: occurrence)
        let sourceState = state(of: source).state
        let outcome: Truth
        switch sourceState {
        case .disabled:
            outcome = Self.test(operation, expected: expected, answers: [])
        case _ where structure.items[target].calculated:
            outcome = .unknown
        case .enabled:
            outcome = Self.test(operation, expected: expected, answers: answers.map(\.value))
        case .notEvaluated:
            // The outcome is known when it does not depend on whether the question is enabled.
            let withAnswers = Self.test(operation, expected: expected, answers: answers.map(\.value))
            outcome = withAnswers == Self.test(operation, expected: expected, answers: []) ? withAnswers : .unknown
        }
        let result: ConditionResult.OutcomePayload = switch outcome {
        case .met: .met
        case .notMet: .notMet
        case .unknown: .notEvaluated
        }
        return ConditionResult(
            index: condition.index,
            question: condition.question,
            _operator: operation,
            outcome: result,
            answers: sourceState == .disabled ? [] : answers.map(\.api),
            questionInstance: form.occurrences[source].instance
        )
    }
}


extension ScenarioEvaluation {
    /// Descendants of an answer see only that answer when a condition refers to its question.
    private func sourceAnswers(_ source: Int, for occurrence: Int) -> ArraySlice<ScenarioForm.Answer> {
        let question = form.occurrences[source]
        let path = structure.items[question.item].path
        guard let instance = form.occurrences[occurrence].instance.first(where: { $0.path == path }) else {
            return question.answers[...]
        }
        return question.answers.dropFirst(instance.index).prefix(1)
    }

    /// The instance of `target` that a condition of `occurrence` reads.
    ///
    /// An enclosing instance of the question comes first. Otherwise the condition reads the question in the nearest enclosing group
    /// instance or answer that contains it; when several instances remain, the nearest preceding one, otherwise the nearest following one.
    func resolve(_ target: Int, from occurrence: Int) -> Int? {
        let chain = Array(sequence(first: occurrence) { form.occurrences[$0].parent })
        if let enclosing = chain.first(where: { form.occurrences[$0].item == target }) {
            return enclosing
        }
        let enclosingItems = Set(structure.ancestors(of: form.occurrences[occurrence].item) + [form.occurrences[occurrence].item])
        let shared = structure.ancestors(of: target).first(where: enclosingItems.contains)
        let candidates = (form.instances[target] ?? []).filter { candidate in
            guard let shared else {
                return true
            }
            guard let scope = chain.firstIndex(where: { form.occurrences[$0].item == shared }) else {
                return false
            }
            // Within a question, only the answer that encloses `occurrence` is shared.
            let answer = scope > 0 ? form.occurrences[chain[scope - 1]].answerIndex : nil
            return contains(chain[scope], answer: structure.items[shared].isGroup ? nil : answer, candidate)
        }
        return candidates.last(where: { $0 < occurrence }) ?? candidates.first(where: { $0 > occurrence })
    }

    private func contains(_ scope: Int, answer: Int?, _ candidate: Int) -> Bool {
        var child = candidate
        while let parent = form.occurrences[child].parent {
            if parent == scope {
                return answer == nil || form.occurrences[child].answerIndex == answer
            }
            child = parent
        }
        return false
    }
}


extension ScenarioEvaluation {
    /// Reserve the largest result this form can emit before state evaluation maps answers into evidence arrays.
    /// Disabled sources may ultimately omit evidence; they use the same conservative reservation.
    func reserveReport(in budget: inout ScenarioReportBudget) throws(QuestionnaireScenarios.BoundExceeded) {
        for diagnostic in form.diagnostics { try budget.reserveDiagnostic(diagnostic) }
        for (index, occurrence) in form.occurrences.enumerated() {
            let item = structure.items[occurrence.item]
            try budget.reserveText(item.path, item.linkId, item.linkId) // Item state and retained response.
            for instance in occurrence.instance { try budget.reserveText(instance.path) }
            try budget.reserveConditions(item.conditions.count)
            for condition in item.conditions {
                try budget.reserveText(condition.question, condition.operator)
                guard !item.cyclic, condition.isValid, let target = condition.target,
                      let source = resolve(target, from: index) else { continue }
                for instance in form.occurrences[source].instance { try budget.reserveText(instance.path) }
                for answer in sourceAnswers(source, for: index) { try budget.reserveAnswer(answer.api) }
            }
        }
    }
}
