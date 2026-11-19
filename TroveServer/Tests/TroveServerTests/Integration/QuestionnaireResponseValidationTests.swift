//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import TroveServer
import VaporTesting


/// A response is checked against its exact Questionnaire by Grove's pair rules and by the official validator.
struct QuestionnaireResponseValidationTests {
    enum Mismatch: String, CaseIterable, CustomTestStringConvertible {
        case questionnaireVersion
        case missingRequiredAnswer
        case answerType
        case languageNotOffered

        var testDescription: String { rawValue }

        /// The Grove pair rule that names the mismatch.
        var rule: String {
            switch self {
            case .questionnaireVersion: "questionnaireCanonical"
            case .missingRequiredAnswer: "requiredItem"
            case .answerType: "answerType"
            case .languageNotOffered: "responseLanguage"
            }
        }
    }

    private static var completionMode: [String: Any] {
        [
            "url": "http://hl7.org/fhir/StructureDefinition/questionnaireresponse-completionMode",
            "valueCodeableConcept": ["coding": [["system": "http://terminology.hl7.org/CodeSystem/v3-ParticipationMode", "code": "ELECTRONIC"]]]
        ]
    }

    /// The official validator refuses example.org canonicals in a response, so the pair uses a reserved `.test` domain.
    private static let canonical = "https://questionnaires.trove.test/fhir/Questionnaire/bilingual-de"

    private static func questionnaire() throws -> Data {
        let fixture = try #require(try MultilingualQuestionnaireFixture.all().first { $0.translationLanguage == "de" })
        let text = String(decoding: try fixture.bytes(), as: UTF8.self)
        return Data(text.replacingOccurrences(of: "https://example.org/fhir/Questionnaire/bilingual-de", with: canonical).utf8)
    }

    /// A completed German response to the German fixture, changed by `mismatch`.
    private static func response(_ mismatch: Mismatch? = nil) throws -> Data {
        var visited: [String: Any] = ["linkId": "visited", "answer": [["valueBoolean": true]]]
        var resource: [String: Any] = [
            "resourceType": "QuestionnaireResponse",
            "meta": ["profile": ["https://grovealliance.org/fhir/questionnaire/StructureDefinition/grove-questionnaire-response"]],
            "language": mismatch == .languageNotOffered ? "fr" : "de",
            "extension": [completionMode],
            "identifier": ["system": "https://responses.trove.test/id", "value": "synthetic-1"],
            "questionnaire": canonical + "|" + (mismatch == .questionnaireVersion ? "2.0.0" : "1.0.0"),
            "status": "completed",
            "subject": ["reference": "Patient/synthetic"],
            "authored": "2026-08-19T12:00:00-07:00"
        ]
        if mismatch == .answerType {
            visited["answer"] = [["valueString": "yes"]]
        }
        let coffee = ["system": "urn:oid:2.25.249846150839427180313926152102489201273", "code": "coffee", "display": "Coffee"]
        let drink: [String: Any] = ["linkId": "drink", "answer": [["valueCoding": coffee]]]
        if mismatch != .missingRequiredAnswer {
            resource["item"] = [visited, drink]
        }
        return try JSONSerialization.data(withJSONObject: resource, options: [.sortedKeys])
    }

    @Test
    func matchingResponsePassesGroveRulesAndBindsBothDigests() async throws {
        let service = QuestionnaireResponseValidationService(validator: QuestionnaireWorkerReply.validator())
        let (questionnaire, response) = (try Self.questionnaire(), try Self.response())
        let result = try await service.validate(questionnaire: questionnaire, response: response)
        #expect(result.status == .valid, "\(result.diagnostics)")
        #expect(result.questionnaireSHA256 == FHIRValidationClient.digest(questionnaire))
        #expect(result.responseSHA256 == FHIRValidationClient.digest(response))
        #expect(result.validatorIdentity == QuestionnaireWorkerReply.identity)
    }

    @Test(arguments: Mismatch.allCases)
    func groveRulesRejectAMismatchedResponseEvenWhenTheValidatorAccepts(mismatch: Mismatch) async throws {
        let service = QuestionnaireResponseValidationService(validator: QuestionnaireWorkerReply.validator())
        let result = try await service.validate(questionnaire: Self.questionnaire(), response: Self.response(mismatch))
        #expect(result.status == .invalid)
        let finding = try #require(result.diagnostics.first { $0.rule == mismatch.rule }, "\(result.diagnostics)")
        #expect(finding.source == .grove && finding.severity == .error)
        #expect(finding.language == (mismatch == .languageNotOffered ? "fr" : nil))
    }

    @Test(arguments: [ValidationStatus.unavailable, .incomplete])
    func validatorResultsOtherThanValidNeverMakeAMatchingResponseValid(status: ValidationStatus) async throws {
        let service = QuestionnaireResponseValidationService(validator: QuestionnaireWorkerReply.validator(status: status))
        let result = try await service.validate(questionnaire: Self.questionnaire(), response: Self.response())
        #expect(result.status == status)
        #expect(result.diagnostics.first?.rule == (status == .unavailable ? "validator-unavailable" : "not-evaluated"))
    }

    @Test
    func unreadableResponseIsInvalid() async throws {
        let service = QuestionnaireResponseValidationService(validator: QuestionnaireWorkerReply.validator(status: .invalid, diagnostics: [
            QuestionnaireWorkerReply.finding("Synthetic_Error")
        ]))
        let result = try await service.validate(questionnaire: Self.questionnaire(), response: Data("{".utf8))
        #expect(result.status == .invalid)
        #expect(result.diagnostics.contains { $0.rule == "fhir-structure" })
    }

    @Test(.enabled(if: Environment.get("TROVE_TEST_VALIDATOR_ASSETS") != nil, "Requires the isolated pinned full validator"))
    func fullValidatorChecksResponsesAgainstTheirExactQuestionnaire() async throws {
        try #require(Environment.get("FHIR_VALIDATOR_URL") != nil && Environment.get("FHIR_VALIDATOR_IDENTITY") != nil)
        try await TestApp.withApp { app, _ in
            let service = QuestionnaireResponseValidationService(validator: try FHIRValidationClient(application: app))
            let questionnaire = try Self.questionnaire()
            let matching = try await service.validate(questionnaire: questionnaire, response: Self.response())
            #expect(matching.status == .valid, "\(matching.diagnostics)")
            for mismatch in Mismatch.allCases {
                let result = try await service.validate(questionnaire: questionnaire, response: Self.response(mismatch))
                #expect(result.status == .invalid, "\(mismatch): \(result.diagnostics)")
                #expect(result.diagnostics.contains { $0.rule == mismatch.rule }, "\(mismatch): \(result.diagnostics)")
            }
            // The official validator resolves this exact Questionnaire: it accepts the matching response, rejects a
            // missing required answer itself and cannot resolve another version.
            let official = try FHIRValidationClient(application: app)
            let accepted = try await official.validateQuestionnaireResponse(questionnaire: questionnaire, response: Self.response())
            #expect(accepted.status == .valid, "\(accepted.diagnostics)")
            let missing = try await official.validateQuestionnaireResponse(
                questionnaire: questionnaire, response: Self.response(.missingRequiredAnswer)
            )
            #expect(missing.status == .invalid, "\(missing.diagnostics)")
            #expect(missing.diagnostics.contains { $0.severity == .error && $0.source == .fhir && $0.path.hasPrefix("QuestionnaireResponse") })
            let otherVersion = try await official.validateQuestionnaireResponse(
                questionnaire: questionnaire, response: Self.response(.questionnaireVersion)
            )
            #expect(otherVersion.status == .incomplete, "\(otherVersion.diagnostics)")
            #expect(otherVersion.diagnostics.contains { $0.rule == "Questionnaire_QR_Q_NotFound" })
        }
    }
}
