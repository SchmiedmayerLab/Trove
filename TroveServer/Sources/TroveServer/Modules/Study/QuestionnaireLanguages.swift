//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// The languages a Questionnaire's JSON names: its base `Questionnaire.language` and the `lang` of every standard
/// `translation` extension, wherever it appears.
///
/// Reading accepts any draft text and reports tags as written. It neither validates nor rewrites the resource.
struct QuestionnaireLanguages: Equatable, Sendable {
    static let translationURL = "http://hl7.org/fhir/StructureDefinition/translation"

    /// `Questionnaire.language`, when the text is a JSON object that names one.
    let base: String?
    /// Distinct translation languages, sorted.
    let translations: [String]

    init(_ bytes: Data) {
        let resource = try? JSONSerialization.jsonObject(with: bytes)
        var translations: Set<String> = []
        Self.collect(resource, into: &translations, depth: 0)
        self.base = (resource as? [String: Any])?["language"] as? String
        self.translations = translations.sorted()
    }

    private static func collect(_ value: Any?, into languages: inout Set<String>, depth: Int) {
        guard depth <= 64 else {
            return
        }
        if let array = value as? [Any] {
            for element in array {
                collect(element, into: &languages, depth: depth + 1)
            }
        } else if let object = value as? [String: Any] {
            if object["url"] as? String == translationURL {
                for part in object["extension"] as? [[String: Any]] ?? [] where part["url"] as? String == "lang" {
                    if let language = part["valueCode"] as? String {
                        languages.insert(language)
                    }
                }
            }
            for member in object.values {
                collect(member, into: &languages, depth: depth + 1)
            }
        }
    }
}
