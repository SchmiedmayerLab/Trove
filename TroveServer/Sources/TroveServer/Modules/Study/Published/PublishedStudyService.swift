//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import Grove


final class PublishedStudyService: Module, @unchecked Sendable {
    @Dependency(PublishedStudyRepository.self) var repository
    @Dependency(AuthorizationService.self) var authorizationService
    @Dependency(StudyBundleService.self) var studyBundleService
    @Dependency(ObjectStorageService.self) var storageService

    func publish(studyId: UUID) async throws -> PublishedStudy {
        let study = try await authorizationService.checkResearcherHasStudyAccess(studyId, role: .admin)
        
        let maxRevision = try await repository.maxRevision(forStudyId: studyId)
        let nextRevision = (maxRevision ?? 0) + 1

        let (metadata, _) = try await studyBundleService.buildMetadata(from: study)

        let bundleData = try await studyBundleService.buildBundle(studyId: studyId, revision: nextRevision)
        let bundleKey = "studies/\(studyId)/\(nextRevision).zip"
        try await storageService.upload(data: bundleData, key: bundleKey, contentType: "application/zip")
        let published = PublishedStudy(
            studyId: studyId,
            revision: nextRevision,
            visibility: study.visibility,
            enrollmentCondition: study.enrollmentCondition,
            metadata: metadata
        )

        do {
            return try await repository.create(published)
        } catch where (error as? any DatabaseError)?.isConstraintFailure == true {
            throw ServerError.conflict("Study revision \(nextRevision) already exists")
        }
    }

    func listPublished(studyId: UUID) async throws -> [PublishedStudy] {
        try await authorizationService.checkResearcherHasStudyAccess(studyId, role: .researcher)
        return try await repository.listByStudyId(studyId)
    }

    func browseStudies(studyId: UUID?) async throws -> [PublishedStudy] {
        try authorizationService.checkIsParticipant()

        if let studyId {
            guard let published = try await repository.findLatestPublished(forStudyId: studyId) else {
                return []
            }
            return [published]
        }

        return try await repository.listLatestPublicStudies()
    }
}
