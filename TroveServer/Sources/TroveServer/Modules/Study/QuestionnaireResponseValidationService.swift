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


/// Validates one QuestionnaireResponse against the exact Questionnaire it answers.
///
/// Two independent checks run on the exact bytes: Grove's pair rules (canonical and version, items, answer types,
/// required answers, enablement and the response language) and the official FHIR Validator with the pinned Grove
/// packages. The validator is a remote service, so call this before, never inside, a database transaction. The result
/// binds both digests; a caller that commits based on it must recheck those digests against its own current state in
/// its transaction. A result grants no permission to store or accept the response.
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

    private static func pairRules(questionnaire: Data, response: Data) -> (status: ValidationStatus, diagnostics: [ValidationDiagnostic]) {
        guard let definition = try? JSONDecoder().decode(ModelsR4.Questionnaire.self, from: questionnaire),
              let answers = try? JSONDecoder().decode(ModelsR4.QuestionnaireResponse.self, from: response) else {
            let finding = ValidationDiagnostic.trove(
                "fhir-structure", path: "", message: "The Questionnaire or the QuestionnaireResponse cannot be read as an R4 resource."
            )
            return (.invalid, [finding])
        }
        // No expression evaluator: the supported Questionnaires carry no FHIRPath, and any that does is not evaluated.
        let issues = PairValidator().issues(questionnaire: definition, response: answers)
        let errors = issues.filter { $0.severity == .error }
        let status: ValidationStatus = errors.contains { !notEvaluated.contains($0.code) } ? .invalid : errors.isEmpty ? .valid : .incomplete
        let language = answers.language?.value?.string
        return (status, issues.map { issue in
            .init(
                severity: issue.severity == .error ? .error : .warning,
                source: .grove,
                rule: issue.code.rawValue,
                path: issue.path,
                language: issue.code == .responseLanguage ? language : nil,
                message: issue.message
            )
        })
    }

    /// Only `valid` means both checks ran and passed. Throws only when cancelled.
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
