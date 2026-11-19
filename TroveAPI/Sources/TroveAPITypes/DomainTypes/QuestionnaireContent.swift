//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//


/// One FHIR Questionnaire holding its base language and every translation, as exact JSON text.
///
/// Note: This type is mapped from Components.Schemas.QuestionnaireContent via typeOverrides in the OpenAPI generator config files.
public struct QuestionnaireContent: Hashable, Codable, Sendable {
    /// FHIR Questionnaire JSON; `Questionnaire.language` names the base language.
    public let questionnaire: String

    public init(questionnaire: String) {
        self.questionnaire = questionnaire
    }
}
