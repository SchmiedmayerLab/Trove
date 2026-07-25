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
import StudyPlatformAPIServer
@testable import StudyPlatformServer


enum StudyFixtures {
    @discardableResult
    static func createStudy(
        on database: any Database,
        groupId: UUID,
        id: UUID = UUID(),
        title: String = "Test Study",
        enrollmentCondition: EnrollmentConditions = .none
    ) async throws -> Study {
        let study = Study(
            groupId: groupId,
            locales: [.enUS],
            icon: "heart",
            details: .init([.enUS: StudyDetailContent(title: title)]),
            enrollmentCondition: enrollmentCondition,
            id: id
        )
        try await study.save(on: database)
        return study
    }
}
