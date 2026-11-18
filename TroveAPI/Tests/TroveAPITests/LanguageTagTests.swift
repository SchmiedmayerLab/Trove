//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPITypes


struct LanguageTagTests {
    /// Accepted and rejected tags shared with the TypeScript tests.
    private struct Cases: Decodable {
        static let shared: Self = {
            let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../Fixtures/language-tags.json")
            // A missing shared file fails every test that uses it.
            return (try? JSONDecoder().decode(Self.self, from: Data(contentsOf: url))) ?? Self(accept: [], reject: [])
        }()

        let accept: [String]
        let reject: [String]
    }

    @Test
    func sharedCasesAreAvailable() {
        #expect(!Cases.shared.accept.isEmpty && !Cases.shared.reject.isEmpty)
    }

    @Test(arguments: Cases.shared.accept)
    func acceptsLanguageWithOptionalScriptAndRegion(tag: String) throws {
        let language = try #require(LanguageTag(rawValue: tag))
        #expect(language.rawValue == tag)
        #expect(try JSONDecoder().decode(LanguageTag.self, from: JSONEncoder().encode(language)) == language)
    }

    @Test(arguments: Cases.shared.reject)
    func rejectsOtherForms(tag: String) {
        #expect(LanguageTag(rawValue: tag) == nil)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LanguageTag.self, from: JSONEncoder().encode(tag))
        }
    }

    @Test
    func studyDetailsAreKeyedByLanguageAndIncludeTheirSourceLanguage() throws {
        let json = Data(#"""
            {"sourceLanguage": "de", "content": {
              "de": {"title": "Studie"}, "zh-Hant": {"title": "研究"}, "pt-BR": {"title": "Estudo"}, "ar": {"title": "دراسة"}
            }}
            """#.utf8)
        let details = try JSONDecoder().decode(StudyDetailData.self, from: json)
        #expect(details.sourceLanguage.rawValue == "de")
        #expect(details.source.title == "Studie")
        #expect(Set(details.content.keys.map(\.rawValue)) == ["de", "zh-Hant", "pt-BR", "ar"])
        #expect(try JSONDecoder().decode(StudyDetailData.self, from: JSONEncoder().encode(details)) == details)
    }

    @Test(arguments: [
        #"{"sourceLanguage": "en", "content": {"de": {"title": "Studie"}}}"#,
        #"{"sourceLanguage": "en", "content": {"en": {"title": "Study"}, "en-us": {"title": "Study"}}}"#,
        #"{"sourceLanguage": "en", "content": {}}"#,
        #"{"content": {"en": {"title": "Study"}}}"#
    ])
    func rejectsDetailsWithoutTheirSourceLanguageOrWithInvalidKeys(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(StudyDetailData.self, from: Data(json.utf8))
        }
    }
}
