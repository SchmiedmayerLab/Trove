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

    private var artifacts: ArtifactStore { .init(database: repository.database, storage: storageService) }

    func publish(studyId: UUID) async throws -> PublishedStudy {
        try await authorizationService.checkResearcherHasStudyAccess(studyId, role: .admin)
        
        let maxRevision = try await repository.maxRevision(forStudyId: studyId)
        guard (maxRevision ?? 0) < Int.max else {
            throw ServerError.conflict("The study revision cannot advance")
        }
        let nextRevision = (maxRevision ?? 0) + 1

        let snapshot = try await studyBundleService.preparePublication(studyId: studyId, revision: nextRevision)
        let publicationID = UUID()
        let actor = try AuthContext.checkIsResearcher()
        let event = AuditEvent(
            context: actor.auditContext,
            action: .studyPublished,
            scope: .study(studyID: studyId, groupID: snapshot.groupID),
            target: .init(id: publicationID, version: String(nextRevision))
        )
        let artifact = try await artifacts.stage(
            snapshot.bundle,
            purpose: .publication,
            ownerID: studyId,
            scope: .init(studyID: studyId, groupID: snapshot.groupID)
        )
        let published = PublishedStudy(
            studyId: studyId,
            revision: nextRevision,
            visibility: snapshot.visibility,
            enrollmentCondition: snapshot.enrollmentCondition,
            metadata: snapshot.metadata,
            bundleKey: artifact.key,
            bundleDigest: artifact.digest,
            artifactID: artifact.id,
            consentSnapshot: snapshot.consent,
            collectionPolicy: snapshot.collectionPolicy,
            id: publicationID
        )

        do {
            return try await repository.database.transaction { transaction in
                try await self.artifacts.retain(artifact, on: transaction)
                let result = try await self.repository.create(published, on: transaction)
                try await AuditRepository.recordMutation(event, on: transaction)
                return result
            }
        } catch where (error as? any DatabaseError)?.isConstraintFailure == true {
            throw ServerError.conflict("Study changed before publication could be accepted")
        }
    }

    func participantBundle(studyId: UUID, revision: Int) async throws -> Data {
        _ = try await authorizationService.checkParticipantHasEnrollmentAccess(studyId: studyId)
        guard revision > 0, let published = try await repository.find(studyId: studyId, revision: revision) else {
            throw ServerError.notFound("Published study revision not found")
        }
        let actor = try AuthContext.checkIsParticipant()
        guard let study = try await Study.find(studyId, on: repository.database) else { throw ServerError.notFound("Study not found") }
        let event = AuditEvent(
            context: actor.auditContext,
            action: .studyBundleDisclosure,
            scope: .study(studyID: studyId, groupID: study.$group.id),
            target: .init(id: try published.requireId(), version: String(revision))
        )
        return try await AuditRepository.disclose(event, on: repository.database) { _ in
            try await self.artifacts.download(
                id: published.artifactID,
                ownerID: studyId,
                purpose: .publication,
                expected: (published.bundleKey, published.bundleDigest)
            )
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
