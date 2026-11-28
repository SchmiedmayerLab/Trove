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


struct QuestionnaireValidationServiceTests {
    private static let instant = Date(timeIntervalSince1970: 1_790_035_200)
    private static let fixture = Data(#"""
    {
      "resourceType": "Questionnaire",
      "language": "en-US",
      "meta": {"profile": ["https://grovealliance.org/fhir/questionnaire/StructureDefinition/grove-questionnaire"]},
      "extension": [{
        "url": "http://hl7.org/fhir/StructureDefinition/artifact-versionAlgorithm",
        "valueCoding": {"system": "http://hl7.org/fhir/version-algorithm", "code": "semver"}
      }],
      "url": "https://example.org/fhir/Questionnaire/synthetic-branching",
      "version": "1.0.0", "status": "active", "subjectType": ["Patient"],
      "item": [
        {"linkId": "completed", "text": "Did you complete the synthetic activity?", "type": "boolean", "required": true},
        {"linkId": "duration", "text": "How many minutes?", "type": "integer", "required": true,
         "enableWhen": [{"question": "completed", "operator": "=", "answerBoolean": true}]}
      ]
    }
    """#.utf8)

    private static func service(
        _ status: TroveServer.ValidationStatus = .valid, diagnostics: [ValidationDiagnostic] = []
    ) -> QuestionnaireValidationService {
        .init(validator: QuestionnaireWorkerReply.validator(status: status, diagnostics: diagnostics))
    }

    private static func evidence(_ bytes: Data) async throws -> QuestionnaireValidationService.Evidence {
        let result = try await service().validate(bytes: bytes, evaluationInstant: instant)
        #expect(result.status == .valid, "\(result.diagnostics)")
        return try #require(result.evidence)
    }

    private static func conjunctionTerms(_ condition: GroveQuestionnaire.Questionnaire.Condition) -> [GroveQuestionnaire.Questionnaire.Condition] {
        if case .all(let children) = condition {
            return children.flatMap(conjunctionTerms)
        }
        return [condition]
    }

    @Test
    func bindsExactBytesAndCapabilityWithoutRewriting() async throws {
        let evidence = try await Self.evidence(Self.fixture)
        #expect(evidence.sha256 == SHA256.hash(data: Self.fixture).map { String(format: "%02x", $0) }.joined())
        #expect(evidence.contractRevision == FHIRValidationClient.contractRevision)
        #expect(evidence.executionCapability == "grove-questionnaire-core-v2")
        let restored = try JSONDecoder().decode(QuestionnaireValidationService.Evidence.self, from: JSONEncoder().encode(evidence))
        #expect(restored == evidence)
        let compact = try JSONEncoder().encode(JSONDecoder().decode(ModelsR4.Questionnaire.self, from: Self.fixture))
        let reencoded = try await Self.evidence(compact)
        #expect(reencoded.sha256 != evidence.sha256)
    }

    @Test
    func branchingIsPreservedAndEvaluatedByGrove() throws {
        let resource = try JSONDecoder().decode(ModelsR4.Questionnaire.self, from: Self.fixture)
        let questionnaire = try GroveQuestionnaire.Questionnaire(resource, clock: .fixed(at: Self.instant, in: .gmt))
        let task = try #require(questionnaire.sections.flatMap(\.tasks).first { $0.id == "duration" })
        #expect(Self.conjunctionTerms(task.enabledCondition) == [.responseValueComparison(taskId: "completed", operator: .equal, value: .bool(true))])
        var response = ModelsR4.QuestionnaireResponse(
            identifier: .init(system: "https://example.org/responses", value: "synthetic"),
            item: [
                .init(answer: [.init(value: .boolean(true))], linkId: "completed", text: resource.item?[0].text),
                .init(answer: [.init(value: .integer(5))], linkId: "duration", text: resource.item?[1].text)
            ],
            language: "en-US",
            meta: .init(profile: ["https://grovealliance.org/fhir/questionnaire/StructureDefinition/grove-questionnaire-response"]),
            questionnaire: "https://example.org/fhir/Questionnaire/synthetic-branching|1.0.0",
            status: .init(.completed),
            subject: .init(reference: "Patient/synthetic")
        )
        try PairValidator().validate(questionnaire: resource, response: response)
        response.item?.removeLast()
        #expect(PairValidator().issues(questionnaire: resource, response: response).contains { $0.code == .requiredItem })
        response.item?[0].answer = [.init(value: .boolean(false))]
        try PairValidator().validate(questionnaire: resource, response: response)
    }

    @Test(arguments: [TroveServer.ValidationStatus.invalid, .incomplete, .unavailable])
    func workerResultsOtherThanValidCannotProduceExecutionEvidence(status: TroveServer.ValidationStatus) async throws {
        let finding = status == .invalid ? [QuestionnaireWorkerReply.finding("Synthetic_Error")] : []
        let result = try await Self.service(status, diagnostics: finding).validate(bytes: Self.fixture, evaluationInstant: Self.instant)
        #expect(result.status == status)
        #expect(result.evidence == nil)
        #expect(result.language == "en-US")
        let expected = [.invalid: "Synthetic_Error", .incomplete: "not-evaluated", .unavailable: "validator-unavailable"][status]
        #expect(result.diagnostics.first?.rule == expected)
        #expect(result.diagnostics.first?.severity == .error)
    }

    @Test
    func definiteLocalErrorIsInvalidEvenWhenTheValidatorIsUnavailable() async throws {
        var resource = try JSONDecoder().decode(ModelsR4.Questionnaire.self, from: Self.fixture)
        resource.status = .init(.draft)
        let result = try await Self.service(.unavailable).validate(bytes: JSONEncoder().encode(resource), evaluationInstant: Self.instant)
        #expect(result.status == .invalid)
        #expect(Set(result.diagnostics.map(\.rule)).isSuperset(of: ["validator-unavailable", "status-active"]))
    }

    @Test
    func officialWarningsPassThroughWithoutBlockingValidity() async throws {
        let warning = QuestionnaireWorkerReply.finding("Synthetic_Warning", severity: .warning, path: "Questionnaire.item[0]")
        let result = try await Self.service(diagnostics: [warning]).validate(bytes: Self.fixture, evaluationInstant: Self.instant)
        #expect(result.status == .valid)
        #expect(result.evidence != nil)
        #expect(result.diagnostics == [warning])
    }

    @Test
    func baseLanguageWithoutRegionCannotBePublished() async throws {
        let text = String(decoding: Self.fixture, as: UTF8.self)
        let regionless = Data(text.replacingOccurrences(of: #""language": "en-US""#, with: #""language": "de""#).utf8)
        let result = try await Self.service().validate(bytes: regionless, evaluationInstant: Self.instant)
        #expect(result.status == .invalid)
        #expect(result.diagnostics.map(\.rule) == ["base-language-region"])
        let missing = Data(text.replacingOccurrences(of: #""language": "en-US","#, with: "").utf8)
        let unnamed = try await Self.service().validate(bytes: missing, evaluationInstant: Self.instant)
        #expect(unnamed.status == .invalid)
        #expect(unnamed.diagnostics.map(\.rule) == ["base-language-required"])
        #expect(unnamed.diagnostics.first?.nextAction != nil)
    }

    @Test(arguments: ["required-group", "choice-initial"])
    func rejectsSemanticsTheConverterWouldDiscard(change: String) async throws {
        var resource = try JSONDecoder().decode(ModelsR4.Questionnaire.self, from: Self.fixture)
        if change == "required-group" {
            resource.item = [.init(item: resource.item, linkId: "required-group", required: true, type: .init(.group))]
        } else {
            resource.item = [
                .init(
                    answerOption: [.init(value: .coding(.init(code: "option", system: "https://example.org/options")))],
                    initial: [.init(value: .string("Initial free text"))],
                    linkId: "open-choice",
                    text: "Synthetic choice",
                    type: .init(.openChoice)
                )
            ]
        }
        let result = try await Self.service().validate(bytes: JSONEncoder().encode(resource), evaluationInstant: Self.instant)
        #expect(result.status == .invalid)
        #expect(result.evidence == nil)
        #expect(result.diagnostics.map(\.rule) == [change])
        #expect(result.diagnostics.first?.path == (change == "required-group" ? "Questionnaire.item[0].required" : "Questionnaire.item[0].initial"))
    }

    // Each fixture changes one independent unsupported feature.
    @Test(arguments: ["draft", "extension", "primitive", "modifier", "valueset", "repeats", "attachment", "cycle", "unknown", "empty", "expired"])
    func unsupportedSemanticsFailEvenAfterIGSuccess(change: String) async throws { // swiftlint:disable:this cyclomatic_complexity
        var resource = try JSONDecoder().decode(ModelsR4.Questionnaire.self, from: Self.fixture)
        var items = try #require(resource.item)
        let unknownExtension = ModelsR4.Extension(url: "https://example.org/unsupported", value: .boolean(true))
        switch change {
        case "draft": resource.status = .init(.draft)
        case "extension": items[0].extension = [unknownExtension]
        case "primitive": items[0].text?.extension = [unknownExtension]
        case "modifier": items[0].modifierExtension = [unknownExtension]
        case "valueset": items[0].answerValueSet = "https://example.org/ValueSet/external"
        case "repeats": items[0].repeats = true
        case "attachment": items[0].type = .init(.attachment)
        case "cycle": items[0].enableWhen = [.init(answer: .integer(1), operator: .init(.equal), question: "duration")]
        case "unknown": items[1].enableWhen?[0].question = "missing"
        case "empty": items = []
        case "expired": resource.effectivePeriod = .init(end: .init(DateTime("2020-01-01T00:00:00Z")))
        default: Issue.record("Unexpected test case")
        }
        resource.item = items
        let result = try await Self.service().validate(bytes: JSONEncoder().encode(resource), evaluationInstant: Self.instant)
        #expect(result.status == .invalid)
        #expect(result.evidence == nil)
        let expected: [String: (rule: String, path: String)] = [
            "draft": ("status-active", "Questionnaire.status"),
            "extension": ("extension-location", "Questionnaire.item[0].extension"),
            "primitive": ("translation-only", "Questionnaire.item[0].text.extension[0]"),
            "modifier": ("modifier-extension", "Questionnaire.item[0].modifierExtension"),
            "valueset": ("answer-value-set", "Questionnaire.item[0].answerValueSet"),
            "repeats": ("repeats", "Questionnaire.item[0].repeats"),
            "attachment": ("item-type", "Questionnaire.item[0].type"),
            "cycle": ("dependency-cycle", "Questionnaire.item[0]"),
            "unknown": ("enable-when-target", "Questionnaire.item[1].enableWhen[0].question"),
            "empty": ("grove-model", "Questionnaire"),
            "expired": ("effective-period", "Questionnaire.effectivePeriod.end")
        ]
        let finding = try #require(expected[change])
        #expect(result.diagnostics.contains { $0.rule == finding.rule && $0.path == finding.path && $0.source == .trove }, "\(result.diagnostics)")
    }
}
