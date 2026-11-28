//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import GroveQuestionnaire
import GroveQuestionnaireFHIR
import ModelsR4
import Testing
@testable import TroveServer


struct MultilingualQuestionnaireTests {
    private struct Reply: Encodable {
        let valid = true
        let sha256: String
        let contractRevision = FHIRValidationClient.contractRevision
        let validatorIdentity = "sha256:" + String(repeating: "a", count: 64)
        let purpose = "questionnaire"
    }

    private static let instant = Date(timeIntervalSince1970: 1_790_035_200)
    private static let translation = #"""
        {"url": "http://hl7.org/fhir/StructureDefinition/translation",
         "extension": [{"url": "lang", "valueCode": "de"}, {"url": "content", "valueString": "Übersetzung"}]}
        """#

    private static var service: QuestionnaireValidationService {
        .init(validator: FHIRValidationClient(
            expectedIdentity: "sha256:" + String(repeating: "a", count: 64),
            sendForPurpose: { _, bytes in
                (200, try JSONEncoder().encode(Reply(sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())))
            }
        ))
    }

    /// The bilingual fixture, with `extensions` placed as the primitive extensions of the element at `path`.
    private static func resource(placing extensions: String, at path: [Any]) throws -> Data {
        let fixture = try #require(try MultilingualQuestionnaireFixture.all().first)
        var resource = try #require(try JSONSerialization.jsonObject(with: fixture.bytes()) as? [String: Any])
        let value = try JSONSerialization.jsonObject(with: Data("[\(extensions)]".utf8))
        func place(_ object: Any, _ path: ArraySlice<Any>) -> Any {
            if let key = path.first as? String, var dictionary = object as? [String: Any] {
                if path.count == 1 {
                    dictionary[key] = ["extension": value]
                } else {
                    let missing: Any = path.dropFirst().first is Int ? [[String: Any]()] : [String: Any]()
                    dictionary[key] = place(dictionary[key] ?? missing, path.dropFirst())
                }
                return dictionary
            }
            if let index = path.first as? Int, var array = object as? [Any] {
                array[index] = place(array[index], path.dropFirst())
                return array
            }
            return object
        }
        resource = try #require(place(resource, path[...]) as? [String: Any])
        return try JSONSerialization.data(withJSONObject: resource)
    }

    @Test
    func sharedFixturesNameTheirLanguagesAndRenderEachThroughGrove() throws {
        for fixture in try MultilingualQuestionnaireFixture.all() {
            let bytes = try fixture.bytes()
            let languages = QuestionnaireLanguages(bytes)
            #expect(languages.base == fixture.language, "\(fixture.file)")
            #expect(languages.translations == fixture.translationLanguages, "\(fixture.file)")

            let resource = try JSONDecoder().decode(ModelsR4.Questionnaire.self, from: bytes)
            let questionnaire = try GroveQuestionnaire.Questionnaire(resource, clock: .fixed(at: Self.instant, in: .gmt))
            #expect(questionnaire.languages == [fixture.language] + fixture.translationLanguages, "\(fixture.file)")
            let drink = try #require(questionnaire.sections.flatMap(\.tasks).first { $0.id == "drink" })
            guard case .choice(let config) = drink.kind.variant else {
                Issue.record("\(fixture.file): expected a choice question")
                continue
            }
            for language in [fixture.language, fixture.translationLanguage] {
                #expect(questionnaire.metadata.title.resolved(in: language) == fixture.title[language], "\(fixture.file) \(language)")
                #expect(config.options.map { $0.title.resolved(in: language) } == fixture.answerDisplays[language], "\(fixture.file) \(language)")
            }
        }
    }

    @Test
    func draftLanguagesAreReadWithoutValidation() throws {
        let cases = try MultilingualQuestionnaireFixture.draftLanguageCases()
        #expect(!cases.isEmpty)
        for draft in cases {
            let languages = QuestionnaireLanguages(Data(draft.text.utf8))
            #expect(languages.base == draft.language, "\(draft.name)")
            #expect(languages.translations == draft.translationLanguages, "\(draft.name)")
        }
    }

    @Test
    func validationAdmitsTranslationsAndBindsTheExactBytes() async throws {
        for fixture in try MultilingualQuestionnaireFixture.all() {
            let bytes = try fixture.bytes()
            let evidence = try await Self.service.validate(bytes: bytes, evaluationInstant: Self.instant)
            #expect(evidence.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            #expect(evidence.executionCapability == QuestionnaireValidationService.executionCapability)
            #expect(evidence.language == fixture.language)
            #expect(evidence.translationLanguages == fixture.translationLanguages)
        }
    }

    @Test(arguments: [
        ["_title"], ["_description"], ["_purpose"], ["useContext", 0, "code", "_display"],
        ["useContext", 0, "valueCodeableConcept", "coding", 0, "_display"], ["useContext", 0, "valueCodeableConcept", "_text"],
        ["useContext", 0, "valueQuantity", "_unit"], ["useContext", 0, "valueRange", "high", "_unit"],
        ["useContext", 0, "valueReference", "_display"], ["item", 0, "_text"], ["item", 1, "_prefix"], ["item", 1, "code", 0, "_display"],
        ["item", 1, "answerOption", 0, "valueCoding", "_display"], ["item", 1, "answerOption", 1, "_valueString"]
    ] as [[any Sendable]])
    func translationsAreAdmittedOnRenderedStrings(path: [any Sendable]) throws {
        let bytes = try Self.resource(placing: Self.translation, at: path)
        _ = try JSONDecoder().decode(QuestionnaireExtensionBoundary.self, from: bytes)
    }

    @Test(arguments: [
        ["_name"], ["_url"], ["_version"], ["_language"], ["item", 0, "_linkId"], ["item", 1, "_type"],
        ["item", 1, "answerOption", 0, "valueCoding", "_code"], ["item", 1, "enableWhen", 0, "_question"],
        ["item", 1, "initial", 0, "_valueString"], ["item", 1, "code", 0, "_code"], ["meta", "_versionId"], ["_copyright"],
        ["_publisher"], ["useContext", 0, "code", "_code"], ["item", 0, "item", 0, "answerOption", 0, "valueCoding", "_system"]
    ] as [[any Sendable]])
    func translationsAreRejectedOnDataAndIdentity(path: [any Sendable]) async throws {
        let bytes = try Self.resource(placing: Self.translation, at: path)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(QuestionnaireExtensionBoundary.self, from: bytes)
        }
        await #expect {
            try await Self.service.validate(bytes: bytes, evaluationInstant: Self.instant)
        } throws: { ($0 as? ServerError)?.title == "Unsupported Questionnaire" }
    }

    @Test(arguments: [
        #"{"url": "https://example.org/unsupported", "valueString": "Not a translation"}"#,
        #"{"url": "http://hl7.org/fhir/StructureDefinition/rendering-markdown", "valueMarkdown": "**Rendered**"}"#,
        #"{"url": "http://hl7.org/fhir/StructureDefinition/translation", "extension": [{"url": "lang", "valueCode": "de"}, {"url": "markdown", "valueString": "Text"}]}"#,
        #"{"url": "http://hl7.org/fhir/StructureDefinition/translation", "modifierExtension": [{"url": "https://example.org/modifier", "valueBoolean": true}]}"#,
        #"""
        {"url": "http://hl7.org/fhir/StructureDefinition/translation", "extension": [{"url": "lang", "valueCode": "de"},
         {"url": "content", "valueString": "Text", "_valueString": {"extension": [{"url": "https://example.org/nested", "valueBoolean": true}]}}]}
        """#,
        #"""
        {"url": "http://hl7.org/fhir/StructureDefinition/translation", "extension": [{"url": "lang", "valueCode": "de"},
         {"url": "content", "valueString": "Text", "extension": [{"url": "https://example.org/nested", "valueBoolean": true}]}]}
        """#
    ])
    func displayedStringsCarryOnlyStandardTranslations(extensionJSON: String) throws {
        let bytes = try Self.resource(placing: extensionJSON, at: ["item", 0, "_text"])
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(QuestionnaireExtensionBoundary.self, from: bytes)
        }
    }
}
