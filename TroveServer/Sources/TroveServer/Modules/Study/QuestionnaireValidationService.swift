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


/// IG conformance and supported execution are separate, mandatory publication gates.
struct QuestionnaireValidationService: Sendable {
    struct Evidence: Codable, Equatable, Sendable {
        let sha256: String
        let validatorIdentity: String
        let contractRevision: String
        let executionCapability: String
        /// Time-sensitive eligibility must not outlive the resource's effective period.
        let validUntil: Date?
    }

    static let executionCapability = "grove-questionnaire-core-v1"
    static let unsupported = ServerError(
        status: .unprocessableContent,
        title: "Unsupported Questionnaire",
        detail: "Questionnaire cannot be executed by the supported study client"
    )

    let validator: FHIRValidationClient

    func validate(bytes: Data, evaluationInstant: Date) async throws -> Evidence {
        let identity = try await validator.validateQuestionnaire(bytes)
        let validUntil: Date?
        do {
            _ = try JSONDecoder().decode(QuestionnaireExtensionBoundary.self, from: bytes)
            let resource = try JSONDecoder().decode(ModelsR4.Questionnaire.self, from: bytes)
            try Self.checkExecution(resource, at: evaluationInstant)
            validUntil = try resource.effectivePeriod?.end?.value?.asNSDate()
            _ = try GroveQuestionnaire.Questionnaire(
                resource,
                clock: .fixed(at: evaluationInstant, in: .gmt)
            )
        } catch {
            // Decoder/converter errors can contain researcher-authored content.
            throw Self.unsupported
        }
        return Evidence(
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            validatorIdentity: identity,
            contractRevision: FHIRValidationClient.contractRevision,
            executionCapability: Self.executionCapability,
            validUntil: validUntil
        )
    }
}


extension QuestionnaireValidationService {
    private static func checkExecution(_ resource: ModelsR4.Questionnaire, at instant: Date) throws {
        guard resource.status.value == .active,
              resource.implicitRules == nil,
              resource.contained?.isEmpty != false,
              resource.extension?.allSatisfy({
                  $0.url.value?.url.absoluteString == "http://hl7.org/fhir/StructureDefinition/artifact-versionAlgorithm"
              }) != false else { throw unsupported }
        if let start = resource.effectivePeriod?.start?.value {
            guard start.time != nil, start.timeZone != nil, try start.asNSDate() <= instant else { throw unsupported }
        }
        if let end = resource.effectivePeriod?.end?.value {
            guard end.time != nil, end.timeZone != nil, try end.asNSDate() >= instant else { throw unsupported }
        }
        var items: [String: QuestionnaireItem] = [:]
        var dependencies: [String: [String]] = [:]
        try inspect(resource.item ?? [], parent: nil, items: &items, dependencies: &dependencies)
        var complete: Set<String> = []
        var visiting: Set<String> = []
        for identifier in items.keys {
            try visit(identifier, dependencies: dependencies, complete: &complete, visiting: &visiting)
        }
        for item in items.values {
            for condition in item.enableWhen ?? [] {
                guard let reference = condition.question.value?.string, let target = items[reference],
                      target.type.value != .group, target.type.value != .display else { throw unsupported }
            }
        }
    }

    private static func inspect(
        _ children: [QuestionnaireItem], parent: String?, items: inout [String: QuestionnaireItem], dependencies: inout [String: [String]]
    ) throws {
        for item in children {
            guard let identifier = item.linkId.value?.string, let type = item.type.value,
                  items.count < 512, items.updateValue(item, forKey: identifier) == nil,
                  item.answerValueSet == nil, item.definition == nil,
                  item.repeats?.value?.bool != true || type == .choice || type == .openChoice else { throw unsupported }
            // The current converter does not preserve required groups or non-coded choice initial values.
            guard type != .group || item.required?.value?.bool != true else { throw unsupported }
            if type == .choice || type == .openChoice {
                guard item.initial?.allSatisfy({
                    if case .coding = $0.value { true } else { false }
                }) != false else { throw unsupported }
            }
            switch type {
            case .group, .display, .boolean, .decimal, .integer, .date, .dateTime, .time, .string, .text, .url, .choice, .openChoice, .quantity:
                break
            case .attachment, .reference, .question:
                throw unsupported
            }
            dependencies[identifier] = try (item.enableWhen ?? []).map {
                guard let target = $0.question.value?.string else { throw unsupported }
                return target
            } + (parent.map { [$0] } ?? [])
            try inspect(item.item ?? [], parent: identifier, items: &items, dependencies: &dependencies)
        }
    }

    private static func visit(
        _ identifier: String, dependencies: [String: [String]], complete: inout Set<String>, visiting: inout Set<String>
    ) throws {
        guard !complete.contains(identifier) else {
            return
        }
        guard let references = dependencies[identifier], visiting.insert(identifier).inserted else { throw unsupported }
        for reference in references {
            try visit(reference, dependencies: dependencies, complete: &complete, visiting: &visiting)
        }
        visiting.remove(identifier)
        complete.insert(identifier)
    }
}
