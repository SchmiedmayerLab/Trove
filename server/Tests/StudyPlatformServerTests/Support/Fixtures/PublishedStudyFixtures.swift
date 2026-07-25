//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import SpeziLocalization
import SpeziStudyDefinition
import StudyPlatformAPIServer
@testable import StudyPlatformServer


enum PublishedStudyFixtures {
    @discardableResult
    static func createPublishedStudy(
        on database: any Database,
        studyId: UUID,
        revision: Int = 1,
        visibility: StudyVisibility = .public,
        enrollmentCondition: EnrollmentConditions = .none,
        title: String = "Test Study",
        icon: String = "heart"
    ) async throws -> PublishedStudy {
        let metadata = StudyDefinition.Metadata(
            id: studyId,
            title: .init([.enUS: title]),
            icon: .systemSymbol(icon),
            explanationText: .init([.enUS: ""]),
            shortExplanationText: .init([.enUS: ""]),
            participationCriterion: .all([])
        )
        let published = PublishedStudy(
            studyId: studyId,
            revision: revision,
            visibility: visibility,
            enrollmentCondition: enrollmentCondition,
            metadata: metadata
        )
        try await published.save(on: database)
        return published
    }
}
