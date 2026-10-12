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
    private struct Reply: Encodable {
        let valid: Bool
        let sha256: String
        let contractRevision = FHIRValidationClient.contractRevision
        let validatorIdentity = "sha256:" + String(repeating: "a", count: 64)
        let purpose = "questionnaire"
        let code: String?
    }

    private static let instant = Date(timeIntervalSince1970: 1_790_035_200)
    private static let fixture = Data(#"""
    {
      "resourceType": "Questionnaire",
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

    private static func service(status: Int = 200) -> QuestionnaireValidationService {
        .init(validator: FHIRValidationClient(
            expectedIdentity: "sha256:" + String(repeating: "a", count: 64),
            sendForPurpose: { purpose, bytes in
                #expect(purpose == .questionnaire)
                return (status, try JSONEncoder().encode(Reply(
                    valid: status == 200,
                    sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                    code: status == 422 ? "invalid_fhir" : nil
                )))
            }
        ))
    }

    private static func conjunctionTerms(_ condition: GroveQuestionnaire.Questionnaire.Condition) -> [GroveQuestionnaire.Questionnaire.Condition] {
        if case .all(let children) = condition {
            return children.flatMap(conjunctionTerms)
        }
        return [condition]
    }

    @Test
    func bindsExactBytesAndCapabilityWithoutRewriting() async throws {
        let evidence = try await Self.service().validate(bytes: Self.fixture, evaluationInstant: Self.instant)
        #expect(evidence.sha256 == SHA256.hash(data: Self.fixture).map { String(format: "%02x", $0) }.joined())
        #expect(evidence.contractRevision == FHIRValidationClient.contractRevision)
        #expect(evidence.executionCapability == "grove-questionnaire-core-v1")
        let restored = try JSONDecoder().decode(QuestionnaireValidationService.Evidence.self, from: JSONEncoder().encode(evidence))
        #expect(restored == evidence)
        let compact = try JSONEncoder().encode(JSONDecoder().decode(ModelsR4.Questionnaire.self, from: Self.fixture))
        let reencoded = try await Self.service().validate(bytes: compact, evaluationInstant: Self.instant)
        #expect(reencoded.sha256 != evidence.sha256)
    }

    @Test
    func branchingIsPreservedAndEvaluatedByGrove() throws {
        let resource = try JSONDecoder().decode(ModelsR4.Questionnaire.self, from: Self.fixture)
        let questionnaire = try GroveQuestionnaire.Questionnaire(resource, evaluationInstant: Self.instant)
        let task = try #require(questionnaire.sections.flatMap(\.tasks).first { $0.id == "duration" })
        #expect(Self.conjunctionTerms(task.enabledCondition) == [.responseValueComparison(taskId: "completed", operator: .equal, value: .bool(true))])
        var response = ModelsR4.QuestionnaireResponse(
            identifier: .init(system: "https://example.org/responses", value: "synthetic"),
            item: [
                .init(answer: [.init(value: .boolean(true))], linkId: "completed", text: resource.item?[0].text),
                .init(answer: [.init(value: .integer(5))], linkId: "duration", text: resource.item?[1].text)
            ],
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

    @Test(arguments: [422, 503])
    func workerFailuresCannotProduceExecutionEvidence(status: Int) async throws {
        await #expect {
            try await Self.service(status: status).validate(bytes: Self.fixture, evaluationInstant: Self.instant)
        } throws: { ($0 as? ServerError)?.status.code == status }
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
        let bytes = try JSONEncoder().encode(resource)
        await #expect {
            try await Self.service().validate(bytes: bytes, evaluationInstant: Self.instant)
        } throws: { ($0 as? ServerError)?.status.code == 422 }
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
        let bytes = try JSONEncoder().encode(resource)
        await #expect {
            try await Self.service().validate(bytes: bytes, evaluationInstant: Self.instant)
        } throws: { ($0 as? ServerError)?.status.code == 422 && ($0 as? ServerError)?.title == "Unsupported Questionnaire" }
    }
}
