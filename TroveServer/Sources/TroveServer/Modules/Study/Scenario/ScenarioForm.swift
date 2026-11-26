//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIServer


/// Every item instance of one scenario, with the synthetic answers that fit the Questionnaire.
///
/// The form holds an instance of each item wherever the item can appear, also where the answers omit it, so that a condition reads
/// the instance a participant would see. Instances are stored in document order.
struct ScenarioForm {
    typealias Item = Components.Schemas.QuestionnaireScenarioItem
    typealias Instance = Components.Schemas.QuestionnaireScenarioInstance

    struct Answer {
        let value: ScenarioValue
        /// The answer as given, without nested items.
        let api: Components.Schemas.QuestionnaireScenarioAnswer
        let path: String
    }

    struct Occurrence {
        let item: Int
        let parent: Int?
        /// The answer of the enclosing question that holds this instance.
        let answerIndex: Int?
        let instance: [Instance]
        var answers: [Answer] = []
        var children: [Int] = []
    }

    struct BoundExceeded: Error {}

    private struct Container {
        let parent: Int?
        let answerIndex: Int?
        let instance: [Instance]
        let path: String
    }

    let structure: QuestionnaireStructure
    let limit: Int
    private(set) var occurrences: [Occurrence] = []
    private(set) var roots: [Int] = []
    private(set) var diagnostics: [ValidationDiagnostic] = []
    /// The instances of each item, in document order.
    private(set) var instances: [Int: [Int]] = [:]

    init(structure: QuestionnaireStructure, items: [Item], limit: Int) throws(BoundExceeded) {
        self.structure = structure
        self.limit = limit
        let topLevel = structure.items.indices.filter { structure.items[$0].parent == nil }
        try place(items, into: topLevel, container: Container(parent: nil, answerIndex: nil, instance: [], path: "QuestionnaireResponse"))
    }

    private mutating func place(_ given: [Item], into children: [Int], container: Container) throws(BoundExceeded) {
        var matches: [Int: [(item: Item, path: String)]] = [:]
        for (position, item) in given.enumerated() {
            let path = "\(container.path).item[\(position)]"
            guard let child = children.first(where: { structure.items[$0].linkId == item.linkId }) else {
                diagnostics.append(.trove("answer-item", path: path, message: "No item with linkId '\(item.linkId)' belongs here."))
                continue
            }
            matches[child, default: []].append((item, path))
        }
        for child in children {
            let found = matches[child] ?? []
            if structure.items[child].isGroup {
                try placeGroup(child, found: found, container: container)
            } else {
                try placeQuestion(child, found: found, container: container)
            }
        }
    }

    private mutating func placeGroup(_ child: Int, found: [(item: Item, path: String)], container: Container) throws(BoundExceeded) {
        let definition = structure.items[child]
        let kept = definition.repeats ? found : Array(found.prefix(1))
        for extra in found.dropFirst(kept.count) {
            diagnostics.append(.trove("answer-repeats", path: extra.path, message: "The group does not repeat; only its first instance counts."))
        }
        for (index, entry) in (kept.isEmpty ? [nil] : kept.map(Optional.some)).enumerated() {
            let instance = container.instance + (definition.repeats ? [Instance(path: definition.path, index: index)] : [])
            let occurrence = try append(Occurrence(item: child, parent: container.parent, answerIndex: container.answerIndex, instance: instance))
            if let entry, entry.item.answer?.isEmpty == false {
                diagnostics.append(.trove("answer-on-group", path: "\(entry.path).answer[0]", message: "A group has no answers."))
            }
            try place(
                entry?.item.item ?? [],
                into: definition.children,
                container: Container(parent: occurrence, answerIndex: nil, instance: instance, path: entry?.path ?? definition.path)
            )
        }
    }

    private mutating func placeQuestion(_ child: Int, found: [(item: Item, path: String)], container: Container) throws(BoundExceeded) {
        let definition = structure.items[child]
        for extra in found.dropFirst() {
            diagnostics.append(.trove("answer-duplicate", path: extra.path, message: "The item appears more than once here; only the first counts."))
            for (position, answer) in (extra.item.answer ?? []).enumerated() {
                reportIgnoredItems(under: answer, path: "\(extra.path).answer[\(position)]")
            }
        }
        let occurrence = try append(
            Occurrence(item: child, parent: container.parent, answerIndex: container.answerIndex, instance: container.instance)
        )
        guard let entry = found.first else {
            try placeNested(under: occurrence, answers: [], container: container)
            return
        }
        if entry.item.item?.isEmpty == false {
            diagnostics.append(.trove("answer-nesting", path: "\(entry.path).item[0]", message: "Items under a question belong in its answer."))
        }
        var kept: [(answer: Answer, nested: [Item])] = []
        for (position, answer) in (entry.item.answer ?? []).enumerated() {
            let path = "\(entry.path).answer[\(position)]"
            guard let value = read(answer, of: definition, path: path) else {
                reportIgnoredItems(under: answer, path: path)
                continue
            }
            guard definition.repeats || kept.isEmpty else {
                diagnostics.append(.trove("answer-repeats", path: path, message: "The question does not repeat; only its first valid answer counts."))
                reportIgnoredItems(under: answer, path: path)
                continue
            }
            var stripped = answer
            stripped.item = nil
            kept.append((Answer(value: value, api: stripped, path: path), answer.item ?? []))
        }
        occurrences[occurrence].answers = kept.map(\.answer)
        try placeNested(under: occurrence, answers: kept, container: container)
    }

    private mutating func reportIgnoredItems(under answer: Components.Schemas.QuestionnaireScenarioAnswer, path: String) {
        if answer.item?.isEmpty == false {
            diagnostics.append(.trove("answer-item", path: "\(path).item[0]", message: "Items under an answer that does not count are not evaluated."))
        }
    }

    private mutating func placeNested(
        under occurrence: Int, answers: [(answer: Answer, nested: [Item])], container: Container
    ) throws(BoundExceeded) {
        let definition = structure.items[occurrences[occurrence].item]
        guard !definition.children.isEmpty else {
            for entry in answers where !entry.nested.isEmpty {
                diagnostics.append(.trove(
                    "answer-item", path: "\(entry.answer.path).item[0]", message: "No item belongs under an answer of this question."
                ))
            }
            return
        }
        let containers: [(nested: [Item], path: String)] = answers.isEmpty
            ? [([], definition.path)]
            : answers.map { ($0.nested, $0.answer.path) }
        for (index, entry) in containers.enumerated() {
            try place(entry.nested, into: definition.children, container: Container(
                parent: occurrence,
                answerIndex: index,
                instance: container.instance + [Instance(path: definition.path, index: index)],
                path: entry.path
            ))
        }
    }

    private mutating func append(_ occurrence: Occurrence) throws(BoundExceeded) -> Int {
        guard occurrences.count < limit else {
            throw BoundExceeded()
        }
        let index = occurrences.count
        occurrences.append(occurrence)
        instances[occurrence.item, default: []].append(index)
        if let parent = occurrence.parent {
            occurrences[parent].children.append(index)
        } else {
            roots.append(index)
        }
        return index
    }

    /// The answer's one value if it fits the item, otherwise `nil` with a finding.
    private mutating func read(
        _ answer: Components.Schemas.QuestionnaireScenarioAnswer, of definition: QuestionnaireStructure.Item, path: String
    ) -> ScenarioValue? {
        var stripped = answer
        stripped.item = nil
        guard let kinds = definition.type.flatMap({ QuestionnaireStructure.answerKinds[$0] }) else {
            diagnostics.append(.trove("answer-not-answerable", path: path, message: "This item has no answers."))
            return nil
        }
        guard let object = ScenarioJSON.from(stripped)?.object, object.count == 1, let (key, json) = object.first else {
            diagnostics.append(.trove("answer-value", path: path, message: "An answer needs exactly one value."))
            return nil
        }
        let kind = String(key.dropFirst("value".count))
        guard kinds.contains(kind) else {
            diagnostics.append(.trove("answer-type", path: "\(path).\(key)", message: "\(key) does not answer a \(definition.type ?? "") item."))
            return nil
        }
        guard let value = ScenarioValue.parse(kind: kind, json: json) else {
            diagnostics.append(.trove("answer-value", path: "\(path).\(key)", message: "The value is not a valid FHIR \(kind)."))
            return nil
        }
        return value
    }
}
