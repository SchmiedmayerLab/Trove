//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPITypes


/// The administration languages of one validated questionnaire, with their translation and approval state.
struct QuestionnaireAdministrationCheck: Sendable {
    struct Language: Sendable {
        let language: String
        let translationComplete: Bool
        let approval: QuestionnaireLanguageApproval?
    }

    static let maximumUntranslatedFindings = 50

    let componentID: UUID
    let sha256: String
    let languages: [Language]
    let diagnostics: [ValidationDiagnostic]

    /// `approvals` are the approvals in force for this component; only those for `sha256` count.
    init(
        componentID: UUID,
        bytes: Data,
        administration: QuestionnaireAdministration,
        base: String?,
        translations: [String],
        approvals: [QuestionnaireLanguageApproval]
    ) {
        self.componentID = componentID
        let sha256 = FHIRValidationClient.digest(bytes)
        self.sha256 = sha256
        let path = "components.\(componentID.uuidString.lowercased()).administrationLanguages"
        var diagnostics: [ValidationDiagnostic] = []
        if administration.languages.isEmpty {
            diagnostics.append(.trove(
                "administration-language-required",
                path: path,
                message: "The questionnaire admits no administration language.",
                nextAction: "Admit at least the base language of the questionnaire."
            ))
        }
        var languages: [Language] = []
        for language in administration.languages {
            let (complete, translationFinding) = Self.translationFindings(
                language: language,
                bytes: bytes,
                base: base,
                translations: translations,
                path: path
            )
            var finding = translationFinding
            let approval = approvals.first { $0.componentID == componentID && $0.sha256 == sha256 && $0.language == language }
            if approval == nil {
                finding.append(.trove(
                    "language-approval-missing",
                    path: path,
                    message: "No approval of this exact questionnaire for administration in \(language) is in force.",
                    nextAction: "A study administrator reviews the questionnaire in \(language) and approves it."
                ))
            }
            diagnostics += finding.map { entry in
                var entry = entry.concerning(component: componentID)
                entry.language = language
                return entry
            }
            languages.append(.init(language: language, translationComplete: complete, approval: approval))
        }
        self.languages = languages
        self.diagnostics = diagnostics.map { $0.componentId == nil ? $0.concerning(component: componentID) : $0 }
    }

    /// Whether the resource is completely translated into `language`, with the findings that block it otherwise.
    private static func translationFindings(
        language: String,
        bytes: Data,
        base: String?,
        translations: [String],
        path: String
    ) -> (complete: Bool, findings: [ValidationDiagnostic]) {
        if language == base {
            return (true, [])
        }
        guard translations.contains(language) else {
            return (false, [
                .trove(
                    "administration-language-unknown",
                    path: path,
                    message: "\(language) is neither the base language nor a translation language of the questionnaire.",
                    nextAction: "Add translations into \(language), or stop admitting it."
                )
            ])
        }
        let untranslated = QuestionnaireTranslationCoverage.untranslated(in: bytes, language: language)
        var findings: [ValidationDiagnostic] = untranslated.prefix(maximumUntranslatedFindings).map { element in
            .trove(
                "translation-missing",
                path: element,
                message: "This displayed string has no translation into \(language).",
                nextAction: "Add a translation into \(language), or stop admitting \(language)."
            )
        }
        if untranslated.count > maximumUntranslatedFindings {
            findings.append(.trove(
                "translation-missing",
                path: "Questionnaire",
                message: "\(untranslated.count - maximumUntranslatedFindings) further displayed strings have no translation into \(language)."
            ))
        }
        return (untranslated.isEmpty, findings)
    }
}


/// The languages in which participants may answer one questionnaire component.
///
/// A document wrapper keeps PostgreSQL from storing the list as a native SQL array.
struct QuestionnaireAdministration: Codable, Sendable, Hashable {
    var languages: [String]

    /// The resource's base language as the one administration language, or none when the resource names no base.
    static func base(of questionnaire: QuestionnaireContent) -> Self {
        .init(languages: QuestionnaireLanguages(Data(questionnaire.questionnaire.utf8)).base.map { [$0] } ?? [])
    }

    /// The admitted languages a request names, or the resource's base language when it names none.
    static func resolve(
        _ languages: [String]?, // swiftlint:disable:this discouraged_optional_collection
        questionnaire: QuestionnaireContent
    ) throws -> Self {
        guard let languages else {
            return base(of: questionnaire)
        }
        guard languages.count <= 64, Set(languages).count == languages.count,
              languages.allSatisfy({ (1...35).contains($0.count) && !$0.contains(where: \.isWhitespace) }) else {
            throw ServerError.badRequest("Administration languages must be distinct language codes, at most 64")
        }
        return .init(languages: languages)
    }
}
