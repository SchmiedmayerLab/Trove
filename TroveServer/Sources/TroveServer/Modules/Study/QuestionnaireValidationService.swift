//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import GroveLocalization
import GroveQuestionnaire
import GroveQuestionnaireFHIR
import ModelsR4


/// IG conformance and supported execution are separate, mandatory publication gates.
struct QuestionnaireValidationService: Sendable {
    struct Evidence: Codable, Equatable, Sendable {
        let sha256: String
        /// The base language and the translation languages, as the Grove model of the validated resource names them.
        let language: String
        let translationLanguages: [String]
        let validatorIdentity: String
        let contractRevision: String
        let executionCapability: String
        /// Time-sensitive eligibility must not outlive the resource's effective period.
        let validUntil: Date?
    }

    /// Every finding for one exact resource. Only a `valid` result carries publication evidence.
    struct Result: Sendable {
        let status: ValidationStatus
        let sha256: String
        let language: String?
        let translationLanguages: [String]
        let validatorIdentity: String?
        let diagnostics: [ValidationDiagnostic]
        let evidence: Evidence?
    }

    static let executionCapability = "grove-questionnaire-core-v2"
    static let maximumDiagnostics = 200
    static let unsupported = ServerError(
        status: .unprocessableContent,
        title: "Unsupported Questionnaire",
        detail: "Questionnaire cannot be executed by the supported study client"
    )

    let validator: FHIRValidationClient

    /// Runs the validator and Trove's execution checks on the exact bytes. Throws only when cancelled.
    func validate(bytes: Data, evaluationInstant: Date) async throws -> Result {
        let official = try await validator.validateQuestionnaire(bytes)
        let local = Self.checkLocally(bytes, at: evaluationInstant)
        let status = ValidationStatus.combined([official.status, local.diagnostics.contains { $0.severity == .error } ? .invalid : .valid])
        let sha256 = FHIRValidationClient.digest(bytes)
        var evidence: Evidence?
        if status == .valid, let identity = official.validatorIdentity, let model = local.model {
            evidence = Evidence(
                sha256: sha256,
                language: model.language,
                translationLanguages: model.translationLanguages,
                validatorIdentity: identity,
                contractRevision: FHIRValidationClient.contractRevision,
                executionCapability: Self.executionCapability,
                validUntil: model.validUntil
            )
        }
        // A passing result without evidence lacks the validator identity or the Grove model; it establishes nothing.
        let resultStatus = evidence == nil && status == .valid ? ValidationStatus.unavailable : status
        let reasonStatus = official.status == .valid ? resultStatus : official.status
        let diagnostics = ValidationDiagnostic.ordered(
            (ValidationDiagnostic.reason(for: reasonStatus).map { [$0] } ?? []) + official.diagnostics + local.diagnostics,
            limit: Self.maximumDiagnostics
        )
        return Result(
            status: resultStatus,
            sha256: sha256,
            language: local.model?.language ?? QuestionnaireLanguages(bytes).base,
            translationLanguages: local.model?.translationLanguages ?? QuestionnaireLanguages(bytes).translations,
            validatorIdentity: official.validatorIdentity,
            diagnostics: diagnostics,
            evidence: evidence
        )
    }
}


extension QuestionnaireValidationService {
    private struct Model {
        let language: String
        let translationLanguages: [String]
        let validUntil: Date?
    }

    private static let resourceExtensions: Set<String> = ["http://hl7.org/fhir/StructureDefinition/artifact-versionAlgorithm"]

    /// Trove's extension boundary and execution subset, and the Grove model that execution reads.
    private static func checkLocally(_ bytes: Data, at instant: Date) -> (diagnostics: [ValidationDiagnostic], model: Model?) {
        guard (try? JSONSerialization.jsonObject(with: bytes)) is [String: Any] else {
            // The validator reports text that is not one JSON object.
            return ([], nil)
        }
        var diagnostics = QuestionnaireExtensionBoundary.violations(in: bytes)
        guard let resource = try? JSONDecoder().decode(ModelsR4.Questionnaire.self, from: bytes) else {
            diagnostics.append(.trove(
                "fhir-structure", path: "Questionnaire", message: "The resource cannot be read as an R4 Questionnaire."
            ))
            return (diagnostics, nil)
        }
        diagnostics += checkExecution(resource, at: instant)
        let base = resource.language?.value?.string
        if base == nil {
            diagnostics.append(.trove(
                "base-language-required",
                path: "Questionnaire.language",
                message: "Questionnaire.language must name the language of the base text.",
                nextAction: "Set Questionnaire.language, for example to en-US."
            ))
        } else if let base, LocalizationKey(base) == nil {
            // The pinned Grove bundle names the archived file by the base language, which needs a region.
            diagnostics.append(.trove(
                "base-language-region",
                path: "Questionnaire.language",
                message: "The participant bundle requires a base language with a region.",
                nextAction: "Set Questionnaire.language to a language with a region, for example en-US."
            ))
        }
        guard diagnostics.allSatisfy({ $0.severity != .error }) else {
            return (diagnostics, nil)
        }
        do {
            let questionnaire = try GroveQuestionnaire.Questionnaire(resource, clock: .fixed(at: instant, in: .gmt))
            let languages = questionnaire.languages
            guard questionnaire.metadata.language != nil, let language = languages.first else { throw unsupported }
            return (diagnostics, Model(
                language: language,
                translationLanguages: Array(languages.dropFirst()),
                validUntil: try resource.effectivePeriod?.end?.value?.asNSDate()
            ))
        } catch {
            // Converter errors can contain researcher-authored content; the finding does not repeat them.
            diagnostics.append(.trove(
                "grove-model", path: "Questionnaire", message: "The Grove questionnaire model cannot read this resource."
            ))
            return (diagnostics, nil)
        }
    }

    private static func checkExecution(_ resource: ModelsR4.Questionnaire, at instant: Date) -> [ValidationDiagnostic] {
        checkResource(resource, at: instant) + checkItems(resource.item ?? [])
    }

    private static func checkResource(_ resource: ModelsR4.Questionnaire, at instant: Date) -> [ValidationDiagnostic] {
        var diagnostics: [ValidationDiagnostic] = []
        if resource.status.value != .active {
            diagnostics.append(.trove(
                "status-active",
                path: "Questionnaire.status",
                message: "Only an active Questionnaire can be published.",
                nextAction: "Set Questionnaire.status to active."
            ))
        }
        if resource.implicitRules != nil {
            diagnostics.append(.trove("implicit-rules", path: "Questionnaire.implicitRules", message: "Implicit rules are not supported."))
        }
        if resource.contained?.isEmpty == false {
            diagnostics.append(.trove("contained-resources", path: "Questionnaire.contained", message: "Contained resources are not supported."))
        }
        for (index, element) in (resource.extension ?? []).enumerated()
        where !resourceExtensions.contains(element.url.value?.url.absoluteString ?? "") {
            diagnostics.append(.trove(
                "resource-extension",
                path: "Questionnaire.extension[\(index)]",
                message: "The supported study client reads no extension here other than artifact-versionAlgorithm."
            ))
        }
        for (name, boundary) in [("start", resource.effectivePeriod?.start), ("end", resource.effectivePeriod?.end)] {
            guard let value = boundary?.value else {
                continue
            }
            let path = "Questionnaire.effectivePeriod.\(name)"
            guard value.time != nil, value.timeZone != nil, let date = try? value.asNSDate() else {
                diagnostics.append(.trove("effective-period-precision", path: path, message: "The effective period needs a time and time zone."))
                continue
            }
            if name == "start" ? date > instant : date < instant {
                let message = name == "start" ? "The effective period has not started." : "The effective period has ended."
                diagnostics.append(.trove("effective-period", path: path, message: message))
            }
        }
        return diagnostics
    }

    private static func checkItems(_ children: [QuestionnaireItem]) -> [ValidationDiagnostic] {
        var diagnostics: [ValidationDiagnostic] = []
        var items: [String: (item: QuestionnaireItem, path: String)] = [:]
        var dependencies: [String: [String]] = [:]
        inspect(children, path: "Questionnaire", parent: nil, items: &items, dependencies: &dependencies, diagnostics: &diagnostics)
        var complete: Set<String> = []
        for identifier in items.keys.sorted() {
            var visiting: [String] = []
            if let cycle = cycle(from: identifier, dependencies: dependencies, complete: &complete, visiting: &visiting) {
                diagnostics.append(.trove(
                    "dependency-cycle",
                    path: items[cycle]?.path ?? "Questionnaire",
                    message: "Item '\(cycle)' depends on itself through its conditions or groups."
                ))
            }
        }
        for (identifier, entry) in items.sorted(by: { $0.key < $1.key }) {
            for (index, condition) in (entry.item.enableWhen ?? []).enumerated() {
                let reference: String? = condition.question.value?.string
                let target: QuestionnaireItem? = reference.flatMap { items[$0]?.item }
                let type: QuestionnaireItemType? = target?.type.value
                if target == nil || type == .group || type == .display {
                    diagnostics.append(.trove(
                        "enable-when-target",
                        path: "\(entry.path).enableWhen[\(index)].question",
                        message: "A condition of '\(identifier)' must refer to an answerable item in this Questionnaire."
                    ))
                }
            }
        }
        return diagnostics
    }

    // swiftlint:disable:next function_parameter_count
    private static func inspect(
        _ children: [QuestionnaireItem],
        path parentPath: String,
        parent: String?,
        items: inout [String: (item: QuestionnaireItem, path: String)],
        dependencies: inout [String: [String]],
        diagnostics: inout [ValidationDiagnostic]
    ) {
        for (index, item) in children.enumerated() {
            let path = "\(parentPath).item[\(index)]"
            guard items.count < 512 else {
                diagnostics.append(.trove("item-limit", path: path, message: "The supported study client reads at most 512 items."))
                return
            }
            guard let identifier = item.linkId.value?.string, items[identifier] == nil else {
                diagnostics.append(.trove("link-id-unique", path: "\(path).linkId", message: "Each item needs a linkId that no other item uses."))
                continue
            }
            items[identifier] = (item, path)
            diagnostics += checkItem(item, path: path)
            dependencies[identifier] = (item.enableWhen ?? []).compactMap { $0.question.value?.string } + (parent.map { [$0] } ?? [])
            inspect(item.item ?? [], path: path, parent: identifier, items: &items, dependencies: &dependencies, diagnostics: &diagnostics)
        }
    }

    /// The semantics of one item that the pinned converter would drop or that the study client does not present.
    private static func checkItem(_ item: QuestionnaireItem, path: String) -> [ValidationDiagnostic] {
        var diagnostics: [ValidationDiagnostic] = []
        func add(_ rule: String, _ element: String, _ message: String) {
            diagnostics.append(.trove(rule, path: "\(path).\(element)", message: message))
        }
        let type = item.type.value
        let choice = type == .choice || type == .openChoice
        if item.answerValueSet != nil {
            add("answer-value-set", "answerValueSet", "Answer value sets are not supported; list the options in answerOption.")
        }
        if item.definition != nil {
            add("item-definition", "definition", "Item definitions are not supported.")
        }
        if item.repeats?.value?.bool == true && !choice {
            add("repeats", "repeats", "Only choice items can repeat.")
        }
        if type == .group && item.required?.value?.bool == true {
            add("required-group", "required", "Required groups are not supported; mark the questions in the group as required.")
        }
        if choice && item.initial?.allSatisfy({ if case .coding = $0.value { true } else { false } }) == false {
            add("choice-initial", "initial", "Initial values of choice items must be codings.")
        }
        if type == nil || [.attachment, .reference, .question].contains(type) {
            add("item-type", "type", "The supported study client does not present this item type.")
        }
        return diagnostics
    }

    /// The first item found on a dependency cycle reachable from `identifier`, if any.
    private static func cycle(
        from identifier: String, dependencies: [String: [String]], complete: inout Set<String>, visiting: inout [String]
    ) -> String? {
        guard !complete.contains(identifier) else {
            return nil
        }
        if visiting.contains(identifier) {
            return identifier
        }
        visiting.append(identifier)
        for reference in dependencies[identifier] ?? [] where dependencies[reference] != nil {
            if let found = cycle(from: reference, dependencies: dependencies, complete: &complete, visiting: &visiting) {
                return found
            }
        }
        visiting.removeLast()
        complete.insert(identifier)
        return nil
    }
}
