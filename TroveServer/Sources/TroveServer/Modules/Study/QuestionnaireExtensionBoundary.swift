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
            guard url == "lang" || url == "content" else { throw QuestionnaireValidationService.unsupported }
            try QuestionnaireExtensionBoundary.check(decoder) { _ in nil }
        }
    }

    init(from decoder: any Decoder) throws {
        let url = try decoder.container(keyedBy: QuestionnaireExtensionBoundary.Member.self)
            .decodeIfPresent(String.self, forKey: .url)
        guard url == QuestionnaireLanguages.translationURL else { throw QuestionnaireValidationService.unsupported }
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

    /// Walks an element, decoding the value of its `extension` as the type `extensions` admits at its path.
    fileprivate static func check(_ decoder: any Decoder, extensions: ([any CodingKey]) -> (any Decodable.Type)?) throws {
        guard decoder.codingPath.count <= 64 else { throw QuestionnaireValidationService.unsupported }
        if let container = try? decoder.container(keyedBy: Member.self) {
            for member in container.allKeys {
                switch member.stringValue {
                case "modifierExtension":
                    throw QuestionnaireValidationService.unsupported
                case "extension":
                    guard let admitted = extensions(decoder.codingPath) else { throw QuestionnaireValidationService.unsupported }
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
