//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIServer


/// The items of one Questionnaire with their conditions, read leniently so that every finding keeps its item path.
struct QuestionnaireStructure: Sendable {
    struct Item: Sendable {
        let path: String
        let linkId: String?
        let type: String?
        let text: String?
        let repeats: Bool
        let required: Bool
        let enableBehavior: String?
        let parent: Int?
        var children: [Int] = []
        var conditions: [Condition] = []
        /// The item uses an SDC `enableWhenExpression`, which is not evaluated.
        var enableExpression = false
        /// The item's answers come from an SDC `calculatedExpression`, which is not evaluated.
        var calculated = false
        /// The condition list or its combination rule is malformed.
        var invalidEnablement = false
        var cyclic = false

        var isGroup: Bool {
            type == "group"
        }

        var isAnswerable: Bool {
            type.map { QuestionnaireStructure.answerKinds[$0] != nil } ?? false
        }

        /// Whether the item is a container whose instances form a repeat context for nested items.
        var formsInstances: Bool {
            isGroup ? repeats : type != "display"
        }
    }

    struct Condition: Sendable {
        let index: Int
        let path: String
        let question: String?
        let `operator`: String?
        let expected: ScenarioValue?
        let answer: Components.Schemas.QuestionnaireScenarioAnswer?
        var target: Int?
        var isValid: Bool
    }

    enum BoundExceeded: Error {
        case items
        case depth
        case conditions
    }

    static let maximumItems = 512
    static let maximumDepth = 32
    static let maximumDiagnostics = 200

    var items: [Item] = []
    private(set) var diagnostics: [ValidationDiagnostic] = []
    private(set) var linkIds: [String: Int] = [:]
    private(set) var duplicateLinkIds: Set<String> = []
    private(set) var itemJSON: [[String: ScenarioJSON]] = []

    init(bytes: Data) throws(BoundExceeded) {
        guard let resource = (try? JSONDecoder().decode(ScenarioJSON.self, from: bytes))?.object,
              resource["resourceType"]?.string == "Questionnaire" else {
            diagnostics = [.trove("fhir-structure", path: "Questionnaire", message: "The resource cannot be read as a Questionnaire.")]
            return
        }
        var found: [ValidationDiagnostic] = []
        Self.scanExpressions(in: .object(resource.filter { !["item", "contained"].contains($0.key) }), path: "Questionnaire", into: &found)
        try read(resource["item"], path: "Questionnaire", parent: nil, depth: 1)
        found += diagnostics
        var remainingConditions = ScenarioReportBudget.maximumConditions
        for index in items.indices {
            let count = itemJSON[index]["enableWhen"]?.array?.count ?? 0
            guard count <= remainingConditions else { throw .conditions }
            remainingConditions -= count
            found += inspect(index)
        }
        found += markCycles()
        diagnostics = ValidationDiagnostic.ordered(found, limit: Self.maximumDiagnostics)
    }

    /// The item whose `linkId` is unique and equal to `linkId`.
    func item(linkId: String) -> Int? {
        duplicateLinkIds.contains(linkId) ? nil : linkIds[linkId]
    }

    /// The enclosing items of `index`, nearest first.
    func ancestors(of index: Int) -> [Int] {
        guard let parent = items[index].parent else {
            return []
        }
        return Array(sequence(first: parent) { items[$0].parent })
    }

    private mutating func read(_ json: ScenarioJSON?, path parentPath: String, parent: Int?, depth: Int) throws(BoundExceeded) {
        guard let children = json?.array else {
            if json != nil {
                diagnostics.append(.trove("item-structure", path: "\(parentPath).item", message: "Items must be a JSON array."))
            }
            return
        }
        guard depth <= Self.maximumDepth else {
            throw .depth
        }
        for (position, child) in children.enumerated() {
            let path = "\(parentPath).item[\(position)]"
            guard let object = child.object else {
                diagnostics.append(.trove("item-structure", path: path, message: "An item must be a JSON object."))
                continue
            }
            guard items.count < Self.maximumItems else {
                throw .items
            }
            let index = items.count
            items.append(Item(
                path: path,
                linkId: object["linkId"]?.string,
                type: object["type"]?.string,
                text: object["text"]?.string,
                repeats: object["repeats"]?.bool ?? false,
                required: object["required"]?.bool ?? false,
                enableBehavior: object["enableBehavior"]?.string,
                parent: parent
            ))
            itemJSON.append(object)
            if let parent {
                items[parent].children.append(index)
            }
            if let linkId = items[index].linkId {
                if linkIds[linkId] == nil {
                    linkIds[linkId] = index
                } else {
                    duplicateLinkIds.insert(linkId)
                }
            }
            try read(object["item"], path: path, parent: index, depth: depth + 1)
        }
    }

    /// The structural, expression and condition findings of one item.
    private mutating func inspect(_ index: Int) -> [ValidationDiagnostic] {
        let item = items[index]
        let object = itemJSON[index]
        var found: [ValidationDiagnostic] = []
        if let linkId = item.linkId {
            if linkIds[linkId] != index {
                found.append(.trove("link-id-unique", path: "\(item.path).linkId", message: "Another item already uses linkId '\(linkId)'."))
            }
        } else {
            found.append(.trove("link-id-missing", path: "\(item.path).linkId", message: "The item has no linkId."))
        }
        if item.type.map({ !item.isAnswerable && !["group", "display"].contains($0) }) ?? true {
            found.append(.trove("item-type", path: "\(item.path).type", message: "The item has no FHIR R4 Questionnaire item type."))
        }
        for element in object["extension"]?.array ?? [] where element["valueExpression"] != nil {
            switch element["url"]?.string {
            case Self.enableWhenExpressionURL: items[index].enableExpression = true
            case Self.calculatedExpressionURL: items[index].calculated = true
            default: break
            }
        }
        Self.scanExpressions(in: .object(object.filter { $0.key != "item" }), path: item.path, into: &found)
        found += readConditions(of: index)
        return found
    }
}


extension QuestionnaireStructure {
    static let enableWhenExpressionURL = "http://hl7.org/fhir/uv/sdc/StructureDefinition/sdc-questionnaire-enableWhenExpression"
    static let calculatedExpressionURL = "http://hl7.org/fhir/uv/sdc/StructureDefinition/sdc-questionnaire-calculatedExpression"

    /// Every expression found anywhere in `json`, which this evaluator does not evaluate.
    static func scanExpressions(in json: ScenarioJSON, path: String, into found: inout [ValidationDiagnostic]) {
        switch json {
        case .object(let object):
            if object["valueExpression"] != nil {
                let url = object["url"]?.string ?? "an extension"
                found.append(.trove(
                    "expression-not-evaluated",
                    path: path,
                    message: "The expression in '\(url)' is not evaluated, so branches that depend on it are not verified.",
                    severity: .warning
                ))
            }
            for key in object.keys.sorted() {
                // A primitive's extensions sit under `_name` in JSON and under `name` in FHIRPath.
                let name = key.hasPrefix("_") ? String(key.dropFirst()) : key
                scanExpressions(in: object[key] ?? .null, path: "\(path).\(name)", into: &found)
            }
        case .array(let array):
            for (position, element) in array.enumerated() {
                scanExpressions(in: element, path: "\(path)[\(position)]", into: &found)
            }
        case .null, .bool, .number, .string:
            break
        }
    }
}
