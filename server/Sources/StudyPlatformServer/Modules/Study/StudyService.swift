//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Logging
import Spezi


final class StudyService: Module, @unchecked Sendable {
    @Dependency(StudyRepository.self) var repository
    @Dependency(AuthorizationService.self) var authorizationService

    func getStudy(id: UUID) async throws -> Study {
        try await authorizationService.checkResearcherHasStudyAccess(id, role: .researcher)
    }

    func createStudy(groupId: UUID, study: Study) async throws -> Study {
        try await authorizationService.checkResearcherHasGroupAccess(groupId, role: .admin)
        return try await repository.create(study)
    }

    func listStudies(groupId: UUID) async throws -> [Study] {
        try await authorizationService.checkResearcherHasGroupAccess(groupId, role: .researcher)
        return try await repository.listAll(groupId: groupId)
    }

    func patchStudy(id: UUID, patch: StudyPatch) async throws -> Study {
        let study = try await authorizationService.checkResearcherHasStudyAccess(id, role: .researcher)
        study.apply(patch)
        return try await repository.update(study)
    }

    func deleteStudy(id: UUID) async throws {
        try await authorizationService.checkResearcherHasStudyAccess(id, role: .admin)

        let deleted = try await repository.delete(id: id)
        if !deleted {
            throw ServerError.notFound(resource: "Study", identifier: id.uuidString)
        }
    }
}
