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
    @Test(arguments: ["de", "zh-Hant", "pt-BR", "ar", "es-419", "sr-Latn-RS", "yue"])
    func acceptsLanguageWithOptionalScriptAndRegion(tag: String) throws {
        let language = try #require(LanguageTag(rawValue: tag))
        #expect(language.rawValue == tag)
        #expect(try JSONDecoder().decode(LanguageTag.self, from: JSONEncoder().encode(language)) == language)
    }

    @Test(arguments: [
        "", "DE", "de-de", "zh-hant", "en_US", "de-", "-de", "e", "deutsch", "pt-BRA", "en-US-x-private", "zh-Hant-TW-x", "dé", "de-DE "
    ])
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
