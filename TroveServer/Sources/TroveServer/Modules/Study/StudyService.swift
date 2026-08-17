//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Grove
import Logging


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
