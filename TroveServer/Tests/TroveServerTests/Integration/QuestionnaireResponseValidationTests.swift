//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import Testing
import TroveAPIServer
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

    static func questionnaire() throws -> Data {
        let fixture = try #require(try MultilingualQuestionnaireFixture.all().first { $0.translationLanguage == "de" })
        let text = String(decoding: try fixture.bytes(), as: UTF8.self)
        return Data(text.replacingOccurrences(of: "https://example.org/fhir/Questionnaire/bilingual-de", with: canonical).utf8)
    }

    /// The German fixture whose second item is enabled by an expression that fails when evaluated.
    private static func questionnaireWithUncheckableCondition() throws -> Data {
        var resource = try #require(try JSONSerialization.jsonObject(with: questionnaire()) as? [String: Any])
        var items = try #require(resource["item"] as? [[String: Any]])
        items[1]["enableWhen"] = nil
        let condition: [String: Any] = [
            "url": "http://hl7.org/fhir/uv/sdc/StructureDefinition/sdc-questionnaire-enableWhenExpression",
            "valueExpression": ["language": "text/fhirpath", "expression": "%resource.item.where(linkId='visited').answer.value.foo()"]
        ]
        items[1]["extension"] = [condition]
        resource["item"] = items
        return try JSONSerialization.data(withJSONObject: resource)
    }

    /// A completed German response to the German fixture, changed by `mismatch`.
    static func response(_ mismatch: Mismatch? = nil) throws -> Data {
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

    /// Duplicate members are rejected by the validator's structure route; its worker tests cover them.
    @Test
    func completionRejectsMislabeledResponseBytes() throws {
        let original = String(decoding: try Self.response(), as: UTF8.self)
        let type = #""resourceType":"QuestionnaireResponse""#
        let mutations = [
            (type + ",", ""),
            (type, #""resourceType":"Observation""#)
        ]
        let language = try #require(LanguageTag(rawValue: "de"))
        for (pattern, replacement) in mutations {
            let changed = original.replacingOccurrences(of: pattern, with: replacement)
            try #require(changed != original)
            let check = QuestionnaireResponseValidationService.validateCompletion(
                questionnaire: try Self.questionnaire(), response: Data(changed.utf8), language: language
            )
            #expect(check.status == .invalid && check.diagnostics.contains { $0.rule == "fhir-structure" })
        }
    }

    @Test
    func completionRequiresTheFrozenLanguageAndFinalStatus() throws {
        let questionnaire = try Self.questionnaire()
        let response = try Self.response()
        let german = try #require(LanguageTag(rawValue: "de"))
        let english = try #require(LanguageTag(rawValue: "en-US"))
        let valid = QuestionnaireResponseValidationService.validateCompletion(questionnaire: questionnaire, response: response, language: german)
        #expect(valid.status == .valid)
        #expect(valid.questionnaireSHA256 == FHIRValidationClient.digest(questionnaire))
        #expect(valid.responseSHA256 == FHIRValidationClient.digest(response))
        let wrongLanguage = QuestionnaireResponseValidationService.validateCompletion(
            questionnaire: questionnaire, response: response, language: english
        )
        #expect(wrongLanguage.status == .invalid && wrongLanguage.diagnostics.contains { $0.rule == "completion-language" })
        var json = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        json["status"] = "in-progress"
        let unfinished = QuestionnaireResponseValidationService.validateCompletion(
            questionnaire: questionnaire, response: try JSONSerialization.data(withJSONObject: json), language: german
        )
        #expect(unfinished.status == .invalid && unfinished.diagnostics.contains { $0.rule == "completion-status" })
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
            // A condition the validator cannot evaluate leaves the answers unchecked against it.
            let uncheckable = try await official.validateQuestionnaireResponse(
                questionnaire: Self.questionnaireWithUncheckableCondition(), response: Self.response()
            )
            #expect(uncheckable.status == .incomplete, "\(uncheckable.diagnostics)")
            #expect(uncheckable.diagnostics.contains { $0.rule == "Questionnaire_QR_Item_EnableWhen_Uncheckable" })
        }
    }
}

extension QuestionnaireResponseValidationTests {
    private static func editDraft(_ original: String, study: Study, component: Component, app: Application, token: String?) async throws {
        var resource = try #require(JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        resource["version"] = "2.0.0"
        let edited = String(decoding: try JSONSerialization.data(withJSONObject: resource, options: [.sortedKeys]), as: UTF8.self)
        let path = try "\(apiBasePath)/studies/\(study.requireId())/components/questionnaire/\(component.requireId())"
        let update = try await app.sendRequest(.PUT, path, beforeRequest: { request in
            request.bearerAuth(token)
            request.headers.replaceOrAdd(name: "If-Match", value: "\"\(study.draftRevision)\"")
            try request.encodeJSONBody(Components.Schemas.QuestionnaireComponentInput(name: component.name, data: .init(questionnaire: edited)))
        })
        try #require(update.status == .ok)
        #expect(try update.content.decode(Components.Schemas.QuestionnaireComponentResponse.self).data.questionnaire == edited)
    }

    @Test
    func participantAnswersUsePublishedBytesAfterADraftEdit() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: QuestionnaireWorkerReply.validator()) { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let studyID = try study.requireId()
            let bytes = try Self.questionnaire()
            let original = String(decoding: bytes, as: UTF8.self)
            let component = Component(
                studyId: studyID, data: .questionnaire(.init(questionnaire: original)), name: "Bilingual questionnaire", id: UUID()
            )
            try await component.create(on: app.db)
            let published = try await PublicationWorkflowFixtures.publish(studyID, app: app, token: token)
            try #require(published.status == .created)
            let publishedID = try published.content.decode(Components.Schemas.PublishedStudyResponse.self).id
            let revision = try #require(try await PublishedStudy.find(UUID(uuidString: publishedID), on: app.db))
            let componentID = try component.requireId()
            try await Self.editDraft(original, study: study, component: component, app: app, token: token)

            let service = app.grove[PublishedStudyService.self]
            let instrument = PublishedStudyService.TaskInstrument(
                studyID: studyID,
                publicationID: try revision.requireId(),
                revision: revision.revision,
                artifactID: revision.artifactID,
                componentID: componentID,
                baseLanguage: "en-US",
                sha256: FHIRValidationClient.digest(bytes)
            )
            let language = try #require(LanguageTag(rawValue: "de"))
            let accepted = try await service.checkTaskResponse(instrument: instrument, sessionLanguage: language, response: Self.response())
            #expect(accepted.status == .valid && accepted.questionnaireSHA256 == instrument.sha256)
            let newer = try await service.checkTaskResponse(
                instrument: instrument, sessionLanguage: language, response: Self.response(.questionnaireVersion)
            )
            #expect(newer.status == .invalid && newer.diagnostics.contains { $0.rule == Mismatch.questionnaireVersion.rule })
        }
    }
}


extension QuestionnaireResponseValidationTests {
    /// Task admission checks the response's own structure with the reusable engine, without its Questionnaire.
    @Test(.enabled(if: Environment.get("TROVE_TEST_VALIDATOR_ASSETS") != nil, "Requires the isolated pinned full validator"))
    func fullValidatorChecksTaskResponseStructure() async throws {
        try #require(Environment.get("FHIR_VALIDATOR_URL") != nil && Environment.get("FHIR_VALIDATOR_IDENTITY") != nil)
        try await TestApp.withApp { app, _ in
            let official = try FHIRValidationClient(application: app)
            #expect(try await official.validateResponseStructure(Self.response()) == Environment.get("FHIR_VALIDATOR_IDENTITY"))
            let duplicate = String(decoding: try Self.response(), as: UTF8.self)
                .replacingOccurrences(of: #""language":"de""#, with: #""language":"de","language":"en-US""#)
            let invalidStatus = String(decoding: try Self.response(), as: UTF8.self)
                .replacingOccurrences(of: #""status":"completed""#, with: #""status":"finished""#)
            for invalid in [duplicate, invalidStatus] {
                await #expect { try await official.validateResponseStructure(Data(invalid.utf8)) } throws: {
                    ($0 as? ServerError)?.status == .unprocessableContent
                }
            }
        }
    }
}
