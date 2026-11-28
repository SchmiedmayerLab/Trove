//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// The bilingual Questionnaires that the Swift and TypeScript tests share, stored once in `TroveAPI/Tests/Fixtures`.
struct MultilingualQuestionnaireFixture: Decodable {
    static let directory = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "../Fixtures/MultilingualQuestionnaires")
        .standardized

    let file: String
    let language: String
    let translationLanguages: [String]

    var url: URL {
        Self.directory.appending(path: file)
    }

    static func all() throws -> [Self] {
        try JSONDecoder().decode([Self].self, from: Data(contentsOf: directory.appending(path: "cases.json")))
    }

    func bytes() throws -> Data {
        try Data(contentsOf: url)
    }
}
