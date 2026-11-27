//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveQuestionnaireFHIR
import ModelsR4
import TroveAPIServer


/// Validates one QuestionnaireResponse against the exact Questionnaire it answers.
///
/// Two independent checks run on the exact bytes: Grove's pair rules (canonical and version, items, answer types,
/// required answers, enablement and the response language) and the official FHIR Validator with the pinned Grove
/// packages. The validator is a remote service, so call this before, never inside, a database transaction. The result
/// binds both digests; a caller that commits based on it must recheck those digests against its own current state in
/// its transaction. A result grants no permission to store or accept the response.
///
/// The worker runs one pair at a time in a separate validator process, which takes seconds. While it runs, that worker
/// validates no events or questionnaires. Do not call this for each participant response on the worker that gates event
/// admission. A result of `unavailable` can be permanent for one pair, because the official validator stops without a
/// result on some inputs, so callers bound their retries.
struct QuestionnaireResponseValidationService: Sendable {
    struct Result: Sendable {
        let status: ValidationStatus
        let questionnaireSHA256: String
        let responseSHA256: String
        let validatorIdentity: String?
        let diagnostics: [ValidationDiagnostic]
    }

    /// Grove findings that state a rule could not be evaluated rather than that it failed.
    static let notEvaluated: Set<ValidationIssue.Code> = [
        .expressionEngineRequired, .expressionEvaluation, .enableWhenEvaluation, .valueSetUnresolved
    ]

    let validator: FHIRValidationClient

    private static func pairRules(
        questionnaire: Data, response: Data, completionLanguage: LanguageTag? = nil
    ) -> (status: ValidationStatus, diagnostics: [ValidationDiagnostic]) {
        guard resourceType(of: questionnaire) == "Questionnaire", resourceType(of: response) == "QuestionnaireResponse",
              let definition = try? JSONDecoder().decode(ModelsR4.Questionnaire.self, from: questionnaire),
              let answers = try? JSONDecoder().decode(ModelsR4.QuestionnaireResponse.self, from: response) else {
            let finding = ValidationDiagnostic.trove(
                "fhir-structure", path: "", message: "The Questionnaire or the QuestionnaireResponse cannot be read as an R4 resource."
            )
            return (.invalid, [finding])
        }
        // No expression evaluator: the supported Questionnaires carry no FHIRPath, and any that does is not evaluated.
        let issues = PairValidator().issues(questionnaire: definition, response: answers)
        let errors = issues.filter { $0.severity == .error }
        var status: ValidationStatus = errors.contains { !notEvaluated.contains($0.code) } ? .invalid : errors.isEmpty ? .valid : .incomplete
        let language = answers.language?.value?.string
        var findings = issues.map { issue -> ValidationDiagnostic in
            .init(
                severity: issue.severity == .error ? .error : .warning,
                source: .grove,
                rule: issue.code.rawValue,
                path: issue.path,
                language: issue.code == .responseLanguage ? language : nil,
                message: issue.message
            )
        }
        if let completionLanguage {
            if answers.status.value != .completed {
                status = .invalid
                findings.append(.trove("completion-status", path: "status", message: "The response must be completed."))
            }
            if language != completionLanguage.rawValue {
                status = .invalid
                findings.append(.trove("completion-language", path: "language", message: "The response must use the session language."))
            }
        }
        return (status, findings)
    }

    /// The typed decoders accept a document without, or with another, `resourceType`.
    ///
    /// Duplicate members are rejected before admission by the validator's strict JSON reading of the same bytes.
    private static func resourceType(of document: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: document) as? [String: Any])?["resourceType"] as? String
    }

    /// Checks the submitted bytes against the instrument and language retained for this occurrence.
    static func validateCompletion(questionnaire: Data, response: Data, language: LanguageTag) -> Result {
        let check = pairRules(questionnaire: questionnaire, response: response, completionLanguage: language)
        let reasons = [ValidationDiagnostic.reason(for: check.status)].compactMap { $0 }
        return Result(
            status: check.status,
            questionnaireSHA256: FHIRValidationClient.digest(questionnaire),
            responseSHA256: FHIRValidationClient.digest(response),
            validatorIdentity: nil,
            diagnostics: ValidationDiagnostic.ordered(reasons + check.diagnostics, limit: QuestionnaireValidationService.maximumDiagnostics)
        )
    }

    /// Only `valid` means both checks reported no error and no skipped check. Throws only when cancelled.
    func validate(questionnaire: Data, response: Data) async throws -> Result {
        let grove = Self.pairRules(questionnaire: questionnaire, response: response)
        let official = try await validator.validateQuestionnaireResponse(questionnaire: questionnaire, response: response)
        var rules: Set<String> = []
        let reasons = [grove.status, official.status].compactMap(ValidationDiagnostic.reason(for:)).filter { rules.insert($0.rule).inserted }
        return Result(
            status: ValidationStatus.combined([grove.status, official.status]),
            questionnaireSHA256: FHIRValidationClient.digest(questionnaire),
            responseSHA256: FHIRValidationClient.digest(response),
            validatorIdentity: official.validatorIdentity,
            diagnostics: ValidationDiagnostic.ordered(
                reasons + official.diagnostics + grove.diagnostics,
                limit: QuestionnaireValidationService.maximumDiagnostics
            )
        )
    }
}
