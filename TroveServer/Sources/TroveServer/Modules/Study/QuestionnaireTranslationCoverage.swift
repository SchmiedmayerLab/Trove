//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// The displayed strings of a Questionnaire that carry no translation into a language.
///
/// The displayed strings are those that QuestionnaireExtensionBoundary admits translations on: the title,
/// description and purpose, use-context displays, and each item's text, prefix, code displays and answer option
/// displays and string values. A string counts as translated when one standard translation extension names the
/// language exactly and carries non-empty content. The check reads the JSON without rewriting it.
enum QuestionnaireTranslationCoverage {
    /// FHIRPaths of the strings without a translation into `language`, in document order.
    static func untranslated(in bytes: Data, language: String) -> [String] {
        guard let resource = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            return ["Questionnaire"]
        }
        var missing: [String] = []
        let wanted = language
        for name in ["title", "description", "purpose"] {
            check(resource, name, path: "Questionnaire", language: wanted, into: &missing)
        }
        for (index, context) in array(resource["useContext"]).enumerated() {
            let path = "Questionnaire.useContext[\(index)]"
            check(object(context["code"]), "display", path: "\(path).code", language: wanted, into: &missing)
            let concept = object(context["valueCodeableConcept"])
            for (position, coding) in array(concept["coding"]).enumerated() {
                check(coding, "display", path: "\(path).valueCodeableConcept.coding[\(position)]", language: wanted, into: &missing)
            }
            check(concept, "text", path: "\(path).valueCodeableConcept", language: wanted, into: &missing)
            check(object(context["valueQuantity"]), "unit", path: "\(path).valueQuantity", language: wanted, into: &missing)
            let range = object(context["valueRange"])
            check(object(range["low"]), "unit", path: "\(path).valueRange.low", language: wanted, into: &missing)
            check(object(range["high"]), "unit", path: "\(path).valueRange.high", language: wanted, into: &missing)
            check(object(context["valueReference"]), "display", path: "\(path).valueReference", language: wanted, into: &missing)
        }
        items(array(resource["item"]), path: "Questionnaire", language: wanted, depth: 0, into: &missing)
        return missing
    }

    private static func items(_ items: [[String: Any]], path: String, language: String, depth: Int, into missing: inout [String]) {
        guard depth < 64 else {
            return
        }
        for (index, item) in items.enumerated() {
            let itemPath = "\(path).item[\(index)]"
            check(item, "text", path: itemPath, language: language, into: &missing)
            check(item, "prefix", path: itemPath, language: language, into: &missing)
            for (position, code) in array(item["code"]).enumerated() {
                check(code, "display", path: "\(itemPath).code[\(position)]", language: language, into: &missing)
            }
            for (position, option) in array(item["answerOption"]).enumerated() {
                let optionPath = "\(itemPath).answerOption[\(position)]"
                check(option, "valueString", path: optionPath, language: language, into: &missing)
                check(object(option["valueCoding"]), "display", path: "\(optionPath).valueCoding", language: language, into: &missing)
            }
            Self.items(array(item["item"]), path: itemPath, language: language, depth: depth + 1, into: &missing)
        }
    }

    /// Records `element.name` when it holds a string without a translation into `language`.
    private static func check(_ element: [String: Any], _ name: String, path: String, language: String, into missing: inout [String]) {
        guard element[name] is String else {
            return
        }
        let translated = array(object(element["_\(name)"])["extension"]).contains { translation in
            guard translation["url"] as? String == QuestionnaireLanguages.translationURL else {
                return false
            }
            let parts = array(translation["extension"])
            let lang = parts.first { $0["url"] as? String == "lang" }?["valueCode"] as? String
            let content = parts.first { $0["url"] as? String == "content" }?["valueString"] as? String
            return lang == language && !(content ?? "").isEmpty
        }
        if !translated {
            missing.append("\(path).\(name)")
        }
    }

    private static func object(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    private static func array(_ value: Any?) -> [[String: Any]] {
        (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }
}
