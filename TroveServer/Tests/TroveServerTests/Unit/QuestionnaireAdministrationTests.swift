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
@testable import TroveServer


struct QuestionnaireAdministrationTests {
    private static func german() throws -> Data {
        try #require(try MultilingualQuestionnaireFixture.all().first { $0.translationLanguage == "de" }).bytes()
    }

    private static func resource(_ change: (inout [String: Any]) -> Void) throws -> Data {
        var resource = try #require(try JSONSerialization.jsonObject(with: german()) as? [String: Any])
        change(&resource)
        return try JSONSerialization.data(withJSONObject: resource)
    }

    private static func approval(_ component: UUID, _ bytes: Data, _ language: String) -> QuestionnaireLanguageApproval {
        .init(
            studyID: UUID(),
            componentID: component,
            sha256: FHIRValidationClient.digest(bytes),
            language: language,
            approver: .init(issuer: "https://issuer.example", subject: "administrator"),
            approvedAt: Date()
        )
    }

    @Test
    func completeTranslationsHaveNoUntranslatedStrings() throws {
        #expect(QuestionnaireTranslationCoverage.untranslated(in: try Self.german(), language: "de").isEmpty)
        #expect(QuestionnaireTranslationCoverage.untranslated(in: try Self.german(), language: "DE").count == 7)
    }

    @Test
    func everyUntranslatedDisplayedStringIsNamed() throws {
        let bytes = try Self.resource { resource in
            resource["description"] = "Untranslated description"
            var items = resource["item"] as? [[String: Any]] ?? []
            items[0]["_text"] = [
                "extension": [
                    [
                        "url": QuestionnaireLanguages.translationURL,
                        "extension": [["url": "lang", "valueCode": "de"], ["url": "content", "valueString": ""]]
                    ]
                ]
            ]
            var options = items[1]["answerOption"] as? [[String: Any]] ?? []
            var coding = options[1]["valueCoding"] as? [String: Any] ?? [:]
            coding.removeValue(forKey: "_display")
            options[1]["valueCoding"] = coding
            options.append(["valueString": "Water"])
            items[1]["answerOption"] = options
            items[1]["item"] = [["linkId": "nested", "type": "display", "text": "Nested"]]
            resource["item"] = items
        }
        #expect(QuestionnaireTranslationCoverage.untranslated(in: bytes, language: "de") == [
            "Questionnaire.description",
            "Questionnaire.item[0].text",
            "Questionnaire.item[1].answerOption[1].valueCoding.display",
            "Questionnaire.item[1].answerOption[2].valueString",
            "Questionnaire.item[1].item[0].text"
        ])
        // Another language is untranslated everywhere a string is displayed.
        #expect(QuestionnaireTranslationCoverage.untranslated(in: try Self.german(), language: "fr").count == 7)
    }

    @Test
    func omittedLanguagesAdmitTheBaseLanguage() throws {
        let content = QuestionnaireContent(questionnaire: String(decoding: try Self.german(), as: UTF8.self))
        #expect(try QuestionnaireAdministration.resolve(nil, questionnaire: content).languages == ["en-US"])
        #expect(try QuestionnaireAdministration.resolve(["de"], questionnaire: content).languages == ["de"])
        #expect(try QuestionnaireAdministration.resolve(nil, questionnaire: .init(questionnaire: "{}")).languages.isEmpty)
        #expect(throws: ServerError.self) { try QuestionnaireAdministration.resolve(["de", "de"], questionnaire: content) }
        #expect(throws: ServerError.self) { try QuestionnaireAdministration.resolve([""], questionnaire: content) }
        #expect(throws: ServerError.self) { try QuestionnaireAdministration.resolve(Array(repeating: "x", count: 65), questionnaire: content) }
    }

    @Test
    func approvalsCountOnlyForTheExactResourceAndLanguage() throws {
        let component = UUID()
        let bytes = try Self.german()
        let edited = try Self.resource { $0["title"] = "Edited" }
        let check = QuestionnaireAdministrationCheck(
            componentID: component,
            bytes: bytes,
            administration: .init(languages: ["en-US", "de"]),
            base: "en-US",
            translations: ["de"],
            approvals: [Self.approval(component, bytes, "en-US"), Self.approval(component, edited, "de"), Self.approval(UUID(), bytes, "de")]
        )
        #expect(check.languages.map { $0.approval != nil } == [true, false])
        #expect(check.diagnostics.map(\.rule) == ["language-approval-missing"])
        #expect(check.diagnostics.first?.language == "de" && check.diagnostics.first?.componentId == component.uuidString)
    }

    @Test
    func emptyAndUnknownLanguagesAreBlockers() throws {
        let component = UUID()
        let bytes = try Self.german()
        let empty = QuestionnaireAdministrationCheck(
            componentID: component, bytes: bytes, administration: .init(languages: []), base: "en-US", translations: ["de"], approvals: []
        )
        #expect(empty.diagnostics.map(\.rule) == ["administration-language-required"])
        let unknown = QuestionnaireAdministrationCheck(
            componentID: component,
            bytes: bytes,
            administration: .init(languages: ["fr"]),
            base: "en-US",
            translations: ["de"],
            approvals: [Self.approval(component, bytes, "fr")]
        )
        #expect(unknown.diagnostics.map(\.rule) == ["administration-language-unknown"])
        #expect(unknown.languages.map(\.translationComplete) == [false])
    }

    @Test
    func untranslatedFindingsAreBounded() throws {
        let bytes = try Self.resource { resource in
            resource["item"] = (0..<60).map { ["linkId": "item-\($0)", "type": "display", "text": "Text \($0)"] }
        }
        let component = UUID()
        let check = QuestionnaireAdministrationCheck(
            componentID: component,
            bytes: bytes,
            administration: .init(languages: ["de"]),
            base: "en-US",
            translations: ["de"],
            approvals: [Self.approval(component, bytes, "de")]
        )
        let missing = check.diagnostics.filter { $0.rule == "translation-missing" }
        #expect(missing.count == QuestionnaireAdministrationCheck.maximumUntranslatedFindings + 1)
        #expect(missing.last?.path == "Questionnaire" && missing.allSatisfy { $0.language == "de" })
    }
}
