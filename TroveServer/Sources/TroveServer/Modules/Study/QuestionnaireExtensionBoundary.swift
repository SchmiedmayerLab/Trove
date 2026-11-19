//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// A standard translation, whose `lang` and `content` parts carry no extensions of their own.
private struct Translation: Decodable {
    private struct Part: Decodable {
        init(from decoder: any Decoder) throws {
            let url = try decoder.container(keyedBy: QuestionnaireExtensionBoundary.Member.self)
                .decodeIfPresent(String.self, forKey: .url)
            guard url == "lang" || url == "content" else {
                try QuestionnaireExtensionBoundary.report(.translationPart, at: decoder.codingPath, in: decoder)
                return
            }
            try QuestionnaireExtensionBoundary.check(decoder) { _ in nil }
        }
    }

    init(from decoder: any Decoder) throws {
        let url = try decoder.container(keyedBy: QuestionnaireExtensionBoundary.Member.self)
            .decodeIfPresent(String.self, forKey: .url)
        guard url == QuestionnaireLanguages.translationURL else {
            try QuestionnaireExtensionBoundary.report(.translationOnly, at: decoder.codingPath, in: decoder)
            return
        }
        try QuestionnaireExtensionBoundary.check(decoder) { _ in [Part].self }
    }
}


/// Checks extension locations, including primitive metadata that a renderer could ignore.
///
/// Only the resource and the strings Grove renders carry extensions: the resource its own, whose URLs execution
/// checks, and a rendered string only standard `translation` extensions. The Grove Questionnaire profile restricts
/// translation languages (`qg-translation-1`), which the official validator checks; this boundary restricts elements.
/// Typed FHIR decoding follows; this traversal neither interprets values nor rewrites bytes.
struct QuestionnaireExtensionBoundary: Decodable {
    enum Violation: String, CaseIterable {
        case extensionLocation = "extension-location"
        case modifierExtension = "modifier-extension"
        case translationOnly = "translation-only"
        case translationPart = "translation-part"
        case nestingDepth = "nesting-depth"
        case structure = "resource-structure"

        var message: String {
            switch self {
            case .extensionLocation:
                "Only the resource and, as translations, its displayed strings can carry extensions."
            case .modifierExtension:
                "Modifier extensions are not supported."
            case .translationOnly:
                "A displayed string can carry only standard translation extensions."
            case .translationPart:
                "A translation has only a lang and a content part, without extensions of their own."
            case .nestingDepth:
                "The resource nests more than 64 levels deep."
            case .structure:
                "An element with extensions does not have the structure FHIR defines for it."
            }
        }
    }

    /// Collects every violation of one traversal; without a collector the first violation throws.
    private final class Collector: @unchecked Sendable {
        var diagnostics: [ValidationDiagnostic] = []
    }

    fileprivate struct Member: CodingKey {
        static let url = Self(stringValue: "url")

        let stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            self.init(stringValue: String(intValue))
        }
    }

    // swiftlint:disable:next force_unwrapping
    private static let collectorKey = CodingUserInfoKey(rawValue: "questionnaireExtensionBoundary")!

    /// The strings of the resource and of an item that the pinned Grove converter reads with their translations.
    private static let resourceStrings: Set<[String]> = [
        ["_title"], ["_description"], ["_purpose"],
        ["useContext", "code", "_display"],
        ["useContext", "valueCodeableConcept", "coding", "_display"], ["useContext", "valueCodeableConcept", "_text"],
        ["useContext", "valueQuantity", "_unit"], ["useContext", "valueRange", "low", "_unit"],
        ["useContext", "valueRange", "high", "_unit"], ["useContext", "valueReference", "_display"]
    ]
    private static let itemStrings: Set<[String]> = [
        ["_text"], ["_prefix"], ["code", "_display"], ["answerOption", "_valueString"], ["answerOption", "valueCoding", "_display"]
    ]

    init(from decoder: any Decoder) throws {
        try Self.check(decoder) { path in
            if path.isEmpty {
                Self.self
            } else if Self.displaysText(at: path) {
                [Translation].self
            } else {
                nil
            }
        }
    }

    /// Every extension of a JSON resource placed where it is not admitted, with its FHIRPath.
    ///
    /// Text that is not JSON yields no findings here; the validator reports it.
    static func violations(in bytes: Data) -> [ValidationDiagnostic] {
        let collector = Collector()
        let decoder = JSONDecoder()
        decoder.userInfo[collectorKey] = collector
        do {
            _ = try decoder.decode(Self.self, from: bytes)
        } catch DecodingError.dataCorrupted(let context) where context.codingPath.isEmpty {
            // Not JSON at all.
        } catch {
            collector.diagnostics.append(.trove(Violation.structure.rawValue, path: "Questionnaire", message: Violation.structure.message))
        }
        return collector.diagnostics
    }

    /// The FHIRPath of a coding path: `[item, 0, _text]` as `Questionnaire.item[0].text`.
    static func path(_ codingPath: [any CodingKey]) -> String {
        codingPath.reduce(into: "Questionnaire") { path, key in
            if let index = key.intValue {
                path += "[\(index)]"
            } else {
                path += "." + (key.stringValue.hasPrefix("_") ? String(key.stringValue.dropFirst()) : key.stringValue)
            }
        }
    }

    fileprivate static func report(_ violation: Violation, at codingPath: [any CodingKey], in decoder: any Decoder) throws {
        guard let collector = decoder.userInfo[collectorKey] as? Collector else { throw QuestionnaireValidationService.unsupported }
        collector.diagnostics.append(.trove(violation.rawValue, path: path(codingPath), message: violation.message))
    }

    /// Walks an element, decoding the value of its `extension` as the type `extensions` admits at its path.
    fileprivate static func check(_ decoder: any Decoder, extensions: ([any CodingKey]) -> (any Decodable.Type)?) throws {
        guard decoder.codingPath.count <= 64 else {
            try report(.nestingDepth, at: decoder.codingPath, in: decoder)
            return
        }
        if let container = try? decoder.container(keyedBy: Member.self) {
            for member in container.allKeys {
                switch member.stringValue {
                case "modifierExtension":
                    try report(.modifierExtension, at: decoder.codingPath + [member], in: decoder)
                case "extension":
                    guard let admitted = extensions(decoder.codingPath) else {
                        try report(.extensionLocation, at: decoder.codingPath + [member], in: decoder)
                        continue
                    }
                    _ = try container.decode(admitted, forKey: member)
                default:
                    _ = try container.decode(Self.self, forKey: member)
                }
            }
        } else if var container = try? decoder.unkeyedContainer() {
            while !container.isAtEnd {
                _ = try container.decode(Self.self)
            }
        }
    }

    /// Whether the path names the primitive extensions (`_element`) of a string that Grove renders in the participant's
    /// language: the title, description and purpose, use-context displays, and an item's text, prefix, code displays
    /// and answer option displays and string values.
    private static func displaysText(at path: [any CodingKey]) -> Bool {
        let names = path.filter { $0.intValue == nil }.map(\.stringValue)
        let depth = names.prefix { $0 == "item" }.count
        return depth == 0 ? resourceStrings.contains(names) : itemStrings.contains(Array(names.dropFirst(depth)))
    }
}
