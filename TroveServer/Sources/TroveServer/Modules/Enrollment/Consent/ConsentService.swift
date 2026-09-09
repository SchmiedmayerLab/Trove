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
import GroveStudyDefinition


final class ConsentService: Module, @unchecked Sendable {
    @Dependency(ConsentRepository.self) var repository
    @Dependency(AuthorizationService.self) var authorizationService
    @Dependency(PublishedStudyRepository.self) var publishedStudyRepository
    @Dependency(ObjectStorageService.self) var storageService

    private var artifacts: ArtifactStore { .init(database: repository.database, storage: storageService) }

    func listConsents(enrollmentId: UUID) async throws -> [EnrollmentConsent] {
        let enrollment = try await authorizationService.checkParticipantHasEnrollmentAccess(id: enrollmentId)
        let event = try await auditEvent(
            action: .consentRecordsDisclosure, enrollment: enrollment, consentID: enrollmentId, revision: enrollment.currentRevision
        )
        return try await AuditRepository.disclose(event, on: repository.database) { _ in
            try await self.repository.listConsentRecords(enrollmentId: enrollmentId)
        }
    }

    func getConsentPDF(enrollmentId: UUID, consentId: UUID) async throws -> Data {
        let enrollment = try await authorizationService.checkParticipantHasEnrollmentAccess(id: enrollmentId)
        let consent = try await repository.findConsentRecord(id: consentId, enrollmentId: try enrollment.requireId())
        guard let consent else {
            throw ServerError.notFound("Consent record not found")
        }
        let event = try await auditEvent(
            action: .consentPDFDisclosure, enrollment: enrollment, consentID: consentId, revision: consent.revision
        )
        return try await AuditRepository.disclose(event, on: repository.database) { _ in
            try await self.artifacts.download(
                id: consent.artifactID,
                ownerID: enrollmentId,
                purpose: .consent,
                expected: (consent.evidenceKey, consent.evidenceDigest)
            )
        }
    }

    func getPresentation(
        enrollmentId: UUID, locale: String, revision: Int? = nil
    ) async throws -> (presentation: ConsentPresentation, enrollmentVersion: Int64) {
        let enrollment = try await authorizationService.checkParticipantHasEnrollmentAccess(id: enrollmentId)
        guard enrollment.withdrawnAt == nil else {
            throw ServerError.conflict("Cannot review consent for a withdrawn enrollment")
        }
        let target = revision ?? enrollment.currentRevision
        guard target > 0 else {
            throw ServerError.badRequest("Consent revision must be positive")
        }
        guard target >= enrollment.currentRevision else {
            throw ServerError.conflict("Consent cannot adopt an earlier enrollment revision")
        }
        return (try await presentation(for: enrollment, revision: target, locale: locale), enrollment.stateVersion)
    }

    private func presentation(for enrollment: Enrollment, revision: Int, locale: String) async throws -> ConsentPresentation {
        guard let published = try await publishedStudyRepository.find(studyId: enrollment.$study.id, revision: revision) else {
            throw ServerError.notFound("Reviewed study revision not found")
        }
        return try ConsentPresentation(published: published, locale: locale)
    }

    // The endpoint's explicit command fields are grouped internally after authorization.
    // swiftlint:disable:next function_parameter_count
    func createConsent(
        enrollmentId: UUID,
        commandID: UUID,
        expectedEnrollmentVersion: Int64,
        reviewedRevision: Int,
        presentationProof: ConsentPresentationProof,
        userResponses: UserResponses,
        pdfData: Data
    ) async throws -> EnrollmentConsent {
        let authorizedEnrollment = try await authorizationService.checkParticipantHasEnrollmentAccess(id: enrollmentId)
        let enrollmentUUID = try authorizedEnrollment.requireId()
        let command = ConsentCommand(
            enrollmentID: enrollmentUUID,
            commandID: commandID,
            expectedVersion: expectedEnrollmentVersion,
            reviewedRevision: reviewedRevision,
            proof: presentationProof,
            responses: userResponses,
            evidence: pdfData
        )
        let participantID = authorizedEnrollment.$participant.id
        let preparation = try await prepare(command, participantID: participantID)
        if let receipt = preparation.receipt {
            return try await discloseReceipt(receipt, enrollment: preparation.enrollment)
        }
        let enrollment = preparation.enrollment
        let consentID = UUID()
        let context = try await verifiedStudyContext(enrollment: enrollment)
        let event = AuditEvent(
            context: context.audit,
            action: .consentRecorded,
            scope: .study(studyID: context.scope.studyID, groupID: context.scope.groupID),
            target: .init(id: consentID, version: String(reviewedRevision))
        )
        let artifact = try await artifacts.stage(pdfData, purpose: .consent, ownerID: enrollmentUUID, scope: context.scope)
        let record = EnrollmentConsent(
            enrollmentId: enrollmentUUID,
            revision: reviewedRevision,
            userResponses: userResponses,
            evidenceKey: artifact.key,
            evidenceDigest: command.evidenceDigest,
            artifactID: artifact.id,
            presentationProof: presentationProof,
            commandID: commandID,
            expectedEnrollmentVersion: expectedEnrollmentVersion,
            acceptedEnrollmentVersion: expectedEnrollmentVersion + 1,
            id: consentID
        )
        let outcome = try await accept(record, command: command, participantID: participantID, event: event, artifact: artifact)
        if outcome.replayed {
            return try await discloseReceipt(outcome.record, enrollment: enrollment)
        }
        return outcome.record
    }

    private func prepare(_ command: ConsentCommand, participantID: UUID) async throws -> (enrollment: Enrollment, receipt: EnrollmentConsent?) {
        try await repository.database.transaction { transaction in
            let participant = try await self.repository.lockParticipant(id: participantID, on: transaction)
            let enrollment = try await self.repository.lockEnrollment(id: command.enrollmentID, on: transaction)
            guard enrollment.$participant.id == participantID else {
                throw ServerError.notFound("Enrollment not found")
            }
            // A receipt is historical evidence, not permission to resume participation.
            if let existing = try await self.repository.findCommand(
                enrollmentID: command.enrollmentID, commandID: command.commandID, on: transaction
            ) {
                return (enrollment, try command.replay(existing))
            }
            guard try await self.repository.findConsentRecord(
                enrollmentId: command.enrollmentID, revision: command.reviewedRevision, on: transaction
            ) == nil else {
                throw ServerError.conflict("Consent already exists for this enrollment revision")
            }
            try command.validateNewSubmission(for: enrollment)
            try await self.validateTarget(command, enrollment: enrollment, participant: participant, on: transaction)
            return (enrollment, nil)
        }
    }

    private func validateTarget(
        _ command: ConsentCommand, enrollment: Enrollment, participant: Participant, on transaction: any Database
    ) async throws {
        guard let published = try await publishedStudyRepository.find(
            studyId: enrollment.$study.id, revision: command.reviewedRevision, on: transaction
        ) else {
            throw ServerError.notFound("Reviewed study revision not found")
        }
        let presentation = try ConsentPresentation(published: published, locale: command.proof.locale)
        try presentation.validate(
            presentationID: command.proof.presentationID,
            locale: command.proof.locale,
            digest: command.proof.digest,
            responses: command.responses
        )
        let environment = StudyDefinition.ParticipationCriterion.EvaluationEnvironment(
            age: Calendar.current.dateComponents([.year], from: participant.dateOfBirth, to: Date()).year,
            region: Locale.Region(participant.region),
            language: Locale.Language(identifier: participant.language),
            enabledCustomKeys: []
        )
        guard published.metadata.participationCriterion.evaluate(environment) else {
            throw ServerError.forbidden("Participant does not satisfy the reviewed revision's participation criteria")
        }
        if published.enrollmentCondition == .requiresInvitationCode {
            guard let invitationID = enrollment.$invitationCode.id,
                  let invitation = try await InvitationCode.find(invitationID, on: transaction),
                  invitation.$study.id == enrollment.$study.id else {
                throw ServerError.forbidden("The reviewed revision requires retained invitation evidence")
            }
        }
    }

    private func accept(
        _ record: EnrollmentConsent, command: ConsentCommand, participantID: UUID, event: AuditEvent, artifact: ArtifactReference
    ) async throws -> (record: EnrollmentConsent, replayed: Bool) {
        do {
            return try await repository.database.transaction { transaction in
                let participant = try await self.repository.lockParticipant(id: participantID, on: transaction)
                let enrollment = try await self.repository.lockEnrollment(id: command.enrollmentID, on: transaction)
                guard enrollment.$participant.id == participantID else {
                    throw ServerError.notFound("Enrollment not found")
                }
                if let existing = try await self.repository.findCommand(
                    enrollmentID: command.enrollmentID, commandID: command.commandID, on: transaction
                ) {
                    return (try command.replay(existing), true)
                }
                guard try await self.repository.findConsentRecord(
                    enrollmentId: command.enrollmentID, revision: command.reviewedRevision, on: transaction
                ) == nil else {
                    throw ServerError.conflict("Consent already exists for this enrollment revision")
                }
                try command.validateNewSubmission(for: enrollment)
                try await self.validateTarget(command, enrollment: enrollment, participant: participant, on: transaction)
                record.acceptedEnrollmentVersion = try await self.repository.adoptRevision(
                    id: command.enrollmentID, expectedVersion: command.expectedVersion, revision: command.reviewedRevision, on: transaction
                )
                try await self.artifacts.retain(artifact, on: transaction)
                try await record.save(on: transaction)
                try await AuditRepository.recordMutation(event, on: transaction)
                // Return the same persisted timestamp used by replay and collection boundaries.
                // Database drivers can normalize the freshly assigned in-memory Date's precision.
                guard let stored = try await EnrollmentConsent.find(record.requireID(), on: transaction) else {
                    throw ServerError.unexpectedError
                }
                return (stored, false)
            }
        } catch where (error as? any DatabaseError)?.isConstraintFailure == true {
            throw ServerError.conflict("Consent already submitted for this enrollment revision")
        }
    }

    private func discloseReceipt(_ record: EnrollmentConsent, enrollment: Enrollment) async throws -> EnrollmentConsent {
        let event = try await auditEvent(
            action: .consentRecordsDisclosure, enrollment: enrollment, consentID: record.requireId(), revision: record.revision
        )
        return try await AuditRepository.disclose(event, on: repository.database) { _ in record }
    }

    private func auditEvent(action: AuditEvent.Action, enrollment: Enrollment, consentID: UUID, revision: Int) async throws -> AuditEvent {
        let context = try await verifiedStudyContext(enrollment: enrollment)
        return AuditEvent(
            context: context.audit,
            action: action,
            scope: .study(studyID: context.scope.studyID, groupID: context.scope.groupID),
            target: .init(id: consentID, version: String(revision))
        )
    }

    func verifiedStudyContext(enrollment: Enrollment) async throws -> (audit: AuditEvent.Context, scope: StudyArtifactScope) {
        let actor = try AuthContext.checkIsParticipant()
        guard let study = try await Study.find(enrollment.$study.id, on: repository.database) else {
            throw ServerError.notFound("Study not found")
        }
        return (
            actor.auditContext,
            .init(studyID: enrollment.$study.id, groupID: study.$group.id)
        )
    }
}
