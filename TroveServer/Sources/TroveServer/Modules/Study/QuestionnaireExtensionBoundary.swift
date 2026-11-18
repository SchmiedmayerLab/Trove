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
/// Only the resource and the strings a filler displays carry extensions: the resource its own, whose URLs execution
/// checks, and a displayed string only standard `translation` extensions, as the Grove Questionnaire profile allows.
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

    /// The primitive extensions of a translatable string: `_title`, `_description`, an item's `_text` and `_prefix`,
    /// and an answer option's `_valueString` and `valueCoding._display`.
    private static func displaysText(at path: [any CodingKey]) -> Bool {
        let names = path.filter { $0.intValue == nil }.map(\.stringValue)
        guard let element = names.last else {
            return false
        }
        let parents = names.dropLast()
        func isItem(_ names: ArraySlice<String>) -> Bool {
            !names.isEmpty && names.allSatisfy { $0 == "item" }
        }
        switch element {
        case "_title", "_description":
            return parents.isEmpty
        case "_text", "_prefix":
            return isItem(parents)
        case "_valueString":
            return parents.last == "answerOption" && isItem(parents.dropLast())
        case "_display":
            return parents.suffix(2) == ["answerOption", "valueCoding"] && isItem(parents.dropLast(2))
        default:
            return false
        }
    }
}
