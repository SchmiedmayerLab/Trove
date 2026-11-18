//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPIServer


/// The bilingual Questionnaires that the Swift and TypeScript tests share, stored once in `TroveAPI/Tests/Fixtures`.
struct MultilingualQuestionnaireFixture: Decodable, Sendable, CustomTestStringConvertible {
    /// Draft text whose languages the server and the web read without validation.
    struct DraftLanguageCase: Decodable, Sendable {
        let name: String
        let text: String
        let language: String?
        let translationLanguages: [String]
    }

    static let directory = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "../../../../TroveAPI/Tests/Fixtures/MultilingualQuestionnaires")
        .standardized

    let file: String
    let tag: String
    let language: String
    let translationLanguages: [String]
    /// The title in the base language and the translation language.
    let title: [String: String]
    /// The answer options' displays in each language.
    let answerDisplays: [String: [String]]

    var testDescription: String {
        file
    }

    var translationLanguage: String {
        translationLanguages[0]
    }

    static func draftLanguageCases() throws -> [DraftLanguageCase] {
        try JSONDecoder().decode([DraftLanguageCase].self, from: Data(contentsOf: directory.appending(path: "draft-language-cases.json")))
    }

    static func all() throws -> [Self] {
        try JSONDecoder().decode([Self].self, from: Data(contentsOf: directory.appending(path: "cases.json")))
    }

    func bytes() throws -> Data {
        try Data(contentsOf: Self.directory.appending(path: file))
    }

    func content() throws -> QuestionnaireContent {
        QuestionnaireContent(questionnaire: String(decoding: try bytes(), as: UTF8.self))
    }
}
