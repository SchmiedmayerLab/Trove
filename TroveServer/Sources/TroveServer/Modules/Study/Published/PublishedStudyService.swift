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
    @Dependency(StudyRepository.self) var studyRepository
    @Dependency(StudyValidationService.self) var validationService
    @Dependency(ObjectStorageService.self) var storageService

    private var artifacts: ArtifactStore { .init(database: repository.database, storage: storageService) }

    /// A validation ID is the publication identity; exact retries never create a second archive or revision.
    func publish(studyId: UUID, validationID: UUID, expectedRevision: UUID) async throws -> PublishedStudy {
        let access = try await authorizationService.prepareDraftAccess(operation: .publish)
        return try await repository.database.transaction { transaction in
            let study = try await self.studyRepository.lockStudy(id: studyId, on: transaction)
            let context = try await self.authorizationService.authorizeDraft(access, study: study, on: transaction)
            guard let candidate = try await StudyPublicationCandidate.find(validationID, on: transaction),
                  candidate.studyID == studyId, candidate.groupID == study.$group.id else {
                throw ServerError.notFound("Study validation not found")
            }
            guard candidate.draftRevision == expectedRevision else {
                throw ServerError.preconditionFailed("The publication request does not identify the validated draft")
            }
            if let accepted = try await PublishedStudy.find(validationID, on: transaction) {
                guard accepted.$study.id == studyId, accepted.revision == candidate.publicationRevision,
                      accepted.artifactID == candidate.artifactID, accepted.bundleDigest == candidate.bundleDigest else {
                    throw ServerError.internalServerError("Accepted publication identity is inconsistent")
                }
                try await AuditRepository.recordDisclosureIntent(AuditEvent(
                    context: context,
                    action: .studyPublicationDisclosure,
                    scope: .study(studyID: studyId, groupID: study.$group.id),
                    target: .init(id: validationID, version: String(accepted.revision))
                ), on: transaction)
                return accepted
            }

            try study.requireDraftRevision(expectedRevision)
            try candidate.requireCurrentEvidence(validatorIdentity: self.validationService.validator.expectedIdentity, now: Date())
            guard try await StudyValidationService.nextPublicationRevision(studyID: studyId, on: transaction) == candidate.publicationRevision else {
                throw ServerError.conflict("A publication was accepted after validation; validate the draft again")
            }
            return try await self.accept(candidate, context: context, on: transaction)
        }
    }

    private func accept(
        _ candidate: StudyPublicationCandidate, context: AuditEvent.Context, on transaction: any Database
    ) async throws -> PublishedStudy {
        let snapshot = candidate.snapshot
        let publication = PublishedStudy(
            studyId: candidate.studyID,
            revision: candidate.publicationRevision,
            visibility: snapshot.visibility,
            enrollmentCondition: snapshot.enrollmentCondition,
            metadata: snapshot.metadata,
            bundleKey: candidate.artifact.key,
            bundleDigest: candidate.bundleDigest,
            artifactID: candidate.artifactID,
            consentSnapshot: snapshot.consent,
            collectionPolicy: snapshot.collectionPolicy,
            id: try candidate.requireId()
        )
        try await artifacts.retain(candidate.artifact, on: transaction)
        try await publication.create(on: transaction)
        try await AuditRepository.recordMutation(AuditEvent(
            context: context,
            action: .studyPublished,
            scope: .study(studyID: candidate.studyID, groupID: candidate.groupID),
            target: .init(id: candidate.requireId(), version: String(candidate.publicationRevision))
        ), on: transaction)
        // Use the database's timestamp precision for the first response as well
        // as every retry. The in-memory creation timestamp is not the stored value.
        guard let accepted = try await PublishedStudy.find(candidate.requireId(), on: transaction) else {
            throw ServerError.internalServerError("Accepted publication could not be reloaded")
        }
        return accepted
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
