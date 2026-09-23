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


/// Validates one captured draft, then records a short-lived, immutable publication candidate.
/// Validator and object-storage requests never run while holding a database transaction.
final class StudyValidationService: Module, @unchecked Sendable {
    @Dependency(StudyRepository.self) var repository
    @Dependency(AuthorizationService.self) var authorizationService
    @Dependency(StudyBundleService.self) var bundleService
    @Dependency(ObjectStorageService.self) var storageService

    let validator: FHIRValidationClient

    init(validator: FHIRValidationClient) {
        self.validator = validator
    }

    static func nextPublicationRevision(studyID: UUID, on transaction: any Database) async throws -> Int {
        guard transaction.inTransaction else { throw AuditError.transactionRequired }
        let maximum = try await PublishedStudy.query(on: transaction).filter(\.$study.$id == studyID).max(\.$revision) ?? 0
        guard maximum < Int.max else { throw ServerError.conflict("The study publication revision cannot advance") }
        return maximum + 1
    }

    func validate(studyID: UUID, expectedRevision: UUID) async throws -> StudyPublicationCandidate {
        let (study, publicationRevision) = try await capture(studyID: studyID, expectedRevision: expectedRevision)
        let identity = try validator.requireIdentity()
        let createdAt = Date()
        let publication = try bundleService.preparePublication(from: study, revision: publicationRevision)
        let evidence = try await validateQuestionnaires(publication.questionnaires, at: createdAt)
        let expiresAt = evidence.compactMap { $0.validation.validUntil }.reduce(createdAt.addingTimeInterval(3600), min)
        try Task.checkCancellation()
        guard expiresAt > Date() else { throw ServerError.conflict("Questionnaire eligibility expired during validation") }
        let artifact = try await ArtifactStore(database: repository.database, storage: storageService).stage(
            publication.bundle,
            purpose: .publication,
            ownerID: studyID,
            scope: .init(studyID: studyID, groupID: study.$group.id),
            now: createdAt
        )
        let candidate = StudyPublicationCandidate(
            studyID: studyID,
            groupID: study.$group.id,
            draftRevision: expectedRevision,
            publicationRevision: publicationRevision,
            artifact: artifact,
            validatorIdentity: identity,
            snapshot: .init(
                metadata: publication.metadata,
                consent: publication.consent,
                visibility: publication.visibility,
                enrollmentCondition: publication.enrollmentCondition,
                collectionPolicy: publication.collectionPolicy,
                questionnaires: evidence
            ),
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        return try await persist(candidate)
    }

    private func capture(studyID: UUID, expectedRevision: UUID) async throws -> (Study, Int) {
        let access = try await authorizationService.prepareDraftAccess(operation: .validate)
        return try await repository.database.transaction { transaction in
            let locked = try await self.repository.lockStudy(id: studyID, on: transaction)
            let context = try await self.authorizationService.authorizeDraft(access, study: locked, on: transaction)
            try locked.requireDraftRevision(expectedRevision)
            guard let snapshot = try await self.repository.loadWithComponentsAndSchedules(id: studyID, on: transaction) else {
                throw ServerError.notFound("Study draft not found")
            }
            try await AuditRepository.recordDisclosureIntent(AuditEvent(
                context: context,
                action: .studyDraftDisclosure,
                scope: .study(studyID: studyID, groupID: locked.$group.id),
                target: .init(id: studyID, version: expectedRevision.uuidString)
            ), on: transaction)
            return (snapshot, try await Self.nextPublicationRevision(studyID: studyID, on: transaction))
        }
    }

    private func validateQuestionnaires(
        _ resources: [StudyBundleService.QuestionnaireResource], at instant: Date
    ) async throws -> [StudyPublicationCandidate.QuestionnaireEvidence] {
        let questionnaires = QuestionnaireValidationService(validator: validator)
        var evidence: [StudyPublicationCandidate.QuestionnaireEvidence] = []
        var deadline = instant.addingTimeInterval(3600)
        for resource in resources {
            try Task.checkCancellation()
            guard Date() < deadline else { throw ServerError.conflict("Study validation expired before all resources could be checked") }
            let result = try await questionnaires.validate(bytes: resource.bytes, evaluationInstant: instant)
            evidence.append(.init(componentID: resource.componentID, locale: resource.locale, validation: result))
            if let validUntil = result.validUntil {
                deadline = min(deadline, validUntil)
            }
        }
        return evidence
    }

    private func persist(_ candidate: StudyPublicationCandidate) async throws -> StudyPublicationCandidate {
        // A remote validation may take longer than the authorization freshness window.
        let access = try await authorizationService.prepareDraftAccess(operation: .validate)
        return try await repository.database.transaction { transaction in
            let current = try await self.repository.lockStudy(id: candidate.studyID, on: transaction)
            let context = try await self.authorizationService.authorizeDraft(access, study: current, on: transaction)
            try current.requireDraftRevision(candidate.draftRevision)
            guard current.$group.id == candidate.groupID,
                  try await Self.nextPublicationRevision(studyID: candidate.studyID, on: transaction) == candidate.publicationRevision else {
                throw ServerError.conflict("Publication state changed during validation; validate again")
            }
            try candidate.requireCurrentEvidence(validatorIdentity: self.validator.expectedIdentity, now: Date())
            try await candidate.create(on: transaction)
            try await AuditRepository.recordMutation(AuditEvent(
                context: context,
                action: .studyDraftValidated,
                scope: .study(studyID: candidate.studyID, groupID: candidate.groupID),
                target: .init(id: candidate.requireId(), version: candidate.draftRevision.uuidString)
            ), on: transaction)
            return candidate
        }
    }
}
