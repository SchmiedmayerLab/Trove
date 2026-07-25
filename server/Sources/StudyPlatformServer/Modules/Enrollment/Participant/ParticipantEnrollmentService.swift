//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import Spezi
import SpeziStudyDefinition


final class ParticipantEnrollmentService: Module, @unchecked Sendable {
    @Dependency(EnrollmentRepository.self) var enrollmentRepository
    @Dependency(ProfileService.self) var profileService
    @Dependency(PublishedStudyRepository.self) var publishedStudyRepository
    @Dependency(InvitationCodeService.self) var invitationCodeService
    @Dependency(AuthorizationService.self) var authorizationService

    func enroll(studyId: UUID, invitationCode: String?) async throws -> Enrollment {
        let participant = try await profileService.getProfile()
        let participantId = try participant.requireId()

        guard let publishedStudy = try await publishedStudyRepository.findLatestPublished(forStudyId: studyId) else {
            throw ServerError.notFound(resource: "PublishedStudy", identifier: studyId.uuidString)
        }

        let environment = StudyDefinition.ParticipationCriterion.EvaluationEnvironment(
            age: Calendar.current.dateComponents([.year], from: participant.dateOfBirth, to: Date()).year,
            region: Locale.Region(participant.region),
            language: Locale.Language(identifier: participant.language),
            enabledCustomKeys: []
        )
        guard publishedStudy.metadata.participationCriterion.evaluate(environment) else {
            throw ServerError.forbidden("Participant does not satisfy this study's participation criteria")
        }

        var invitationCodeId: UUID?
        if publishedStudy.enrollmentCondition == .requiresInvitationCode {
            guard let code = invitationCode else {
                throw ServerError.badRequest("This study requires an invitation code")
            }
            invitationCodeId = try await invitationCodeService.validateCode(code, studyId: studyId)
        }

        let enrollment = Enrollment(
            participantId: participantId,
            studyId: studyId,
            currentRevision: publishedStudy.revision,
            invitationCodeId: invitationCodeId
        )

        do {
            return try await enrollmentRepository.create(enrollment)
        } catch where (error as? any DatabaseError)?.isConstraintFailure == true {
            throw ServerError.conflict("Already enrolled in this study or invitation code has already been used")
        }
    }

    func listParticipantEnrollments() async throws -> [Enrollment] {
        let participant = try await profileService.getProfile()
        return try await enrollmentRepository.listByParticipantId(try participant.requireId())
    }

    func withdraw(enrollmentId: UUID) async throws -> Enrollment {
        let enrollment = try await authorizationService.checkParticipantHasEnrollmentAccess(id: enrollmentId)

        if enrollment.withdrawnAt != nil {
            throw ServerError.conflict("Already withdrawn from this study")
        }

        enrollment.withdrawnAt = Date()
        return try await enrollmentRepository.update(enrollment)
    }

    func upgradeToRevision(enrollmentId: UUID, targetRevision: Int) async throws -> Enrollment {
        let enrollment = try await authorizationService.checkParticipantHasEnrollmentAccess(id: enrollmentId)

        if enrollment.withdrawnAt != nil {
            throw ServerError.conflict("Cannot upgrade a withdrawn enrollment")
        }

        if targetRevision <= enrollment.currentRevision {
            throw ServerError.conflict("Target revision must be greater than the current enrollment revision")
        }

        let studyId = enrollment.$study.id
        let publishedRevisions = try await publishedStudyRepository.listByStudyId(studyId)
        guard publishedRevisions.contains(where: { $0.revision == targetRevision }) else {
            throw ServerError.notFound(
                resource: "Revision \(targetRevision) for study",
                identifier: studyId.uuidString
            )
        }

        enrollment.currentRevision = targetRevision
        return try await enrollmentRepository.update(enrollment)
    }
}
