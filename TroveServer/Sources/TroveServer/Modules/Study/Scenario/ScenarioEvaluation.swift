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

        static func not(_ value: Self) -> Self {
            switch value {
            case .met: .notMet
            case .notMet: .met
            case .unknown: .unknown
            }
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

    /// The FHIR operator semantics as R5 words them, which is also R4's intent: `=` and the ordered operators hold when at least one
    /// answer satisfies them, and `!=` holds when no answer has a value equal to the expected one.
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
            // `!=` holds when no answer equals the expected value, so it holds without an answer.
            return Truth.not(Truth.any(answers.map { Self.truth($0.equals(expected)) }))
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
        let answers = form.occurrences[source].answers
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
    /// The instance of `target` that a condition of `occurrence` reads, by the FHIR R4 rule: the nearest occurrence on the ancestor
    /// axis, then on the preceding axis, then on the following axis, in document order of the form's item instances.
    func resolve(_ target: Int, from occurrence: Int) -> Int? {
        if let enclosing = sequence(first: occurrence, next: { form.occurrences[$0].parent }).first(where: { form.occurrences[$0].item == target }) {
            return enclosing
        }
        let candidates = form.instances[target] ?? []
        // Instances are stored in document order, and an ancestor of `occurrence` is never an instance of `target` here.
        return candidates.last(where: { $0 < occurrence })
            ?? candidates.first(where: { $0 > occurrence && !isDescendant($0, of: occurrence) })
    }

    private func isDescendant(_ candidate: Int, of occurrence: Int) -> Bool {
        sequence(first: candidate) { form.occurrences[$0].parent }.dropFirst().contains(occurrence)
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
                for answer in form.occurrences[source].answers { try budget.reserveAnswer(answer.api) }
            }
        }
    }
}
