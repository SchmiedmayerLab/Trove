//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import GroveLocalization
import Testing
import TroveAPIServer
@testable import TroveServer


enum StudyFixtures {
    @discardableResult
    static func createStudy(
        on database: any Database,
        groupId: UUID,
        id: UUID = UUID(),
        title: String = "Test Study",
        enrollmentCondition: EnrollmentConditions = .none,
        readinessFacts: StudyReadinessFacts = completeReadinessFacts()
    ) async throws -> Study {
        let study = Study(
            groupId: groupId,
            locales: [.enUS],
            icon: "heart",
            details: StudyDetailData(sourceLanguage: try #require(LanguageTag(rawValue: "en")), source: StudyDetailContent(title: title)),
            enrollmentCondition: enrollmentCondition,
            readinessFacts: readinessFacts,
            id: id
        )
        try await study.save(on: database)
        return study
    }

    /// Readiness facts that pass every presence check for a study whose details are written in `language`.
    static func completeReadinessFacts(language: String = "en") -> StudyReadinessFacts {
        .init(
            content: .init(additionalProperties: [
                language: .init(
                    aims: "Describe daily wellbeing.",
                    population: "Adults who use the participant app.",
                    procedures: "A daily questionnaire and heart rate collection.",
                    burden: "About two minutes each day.",
                    retention: "Data is kept for five years after the study ends.",
                    withdrawal: "Participants withdraw in the app at any time."
                )
            ]),
            contacts: [.init(name: "Study Coordinator", role: "Coordinator", email: "study@example.org")]
        )
    }

    /// Approves every administration language of every questionnaire component for its stored resource, as an
    /// administrator does before publication. Approvals already in force are kept.
    static func approveAdministrationLanguages(studyID: UUID, on database: any Database) async throws {
        for component in try await Component.query(on: database).filter(\.$study.$id == studyID).all() {
            guard case .questionnaire(let content) = component.data else {
                continue
            }
            let sha256 = FHIRValidationClient.digest(Data(content.questionnaire.utf8))
            let inForce = try await QuestionnaireLanguageApproval.inForce(componentIDs: [component.requireId()], on: database)
            for language in component.administration.languages where !inForce.contains(where: { $0.sha256 == sha256 && $0.language == language }) {
                try await QuestionnaireLanguageApproval(
                    studyID: studyID,
                    componentID: try component.requireId(),
                    sha256: sha256,
                    language: language,
                    approver: .init(issuer: TestApp.issuer, subject: "approving-administrator"),
                    approvedAt: Date()
                )
                .create(on: database)
            }
        }
    }
}
