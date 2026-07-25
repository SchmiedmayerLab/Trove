//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Spezi


final class EnrollmentService: Module, @unchecked Sendable {
    @Dependency(EnrollmentRepository.self) var repository
    @Dependency(AuthorizationService.self) var authorizationService

    func listEnrollments(studyId: UUID) async throws -> [Enrollment] {
        try await authorizationService.checkResearcherHasStudyAccess(studyId, role: .researcher)
        return try await repository.listByStudyId(studyId)
    }
}
