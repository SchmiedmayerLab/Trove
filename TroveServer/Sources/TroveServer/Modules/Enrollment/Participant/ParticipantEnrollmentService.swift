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


final class ParticipantEnrollmentService: Module, @unchecked Sendable {
    @Dependency(EnrollmentRepository.self) var enrollmentRepository
    @Dependency(ProfileService.self) var profileService
    @Dependency(PublishedStudyRepository.self) var publishedStudyRepository
    @Dependency(InvitationCodeService.self) var invitationCodeService
    @Dependency(AuthorizationService.self) var authorizationService
    @Dependency(ConsentRepository.self) var consentRepository

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
        _ = try await authorizationService.checkParticipantHasEnrollmentAccess(id: enrollmentId)

        let actor = try AuthContext.checkIsParticipant()
        return try await enrollmentRepository.database.transaction { transaction in
            let enrollment = try await self.consentRepository.lockEnrollment(id: enrollmentId, on: transaction)
            guard enrollment.withdrawnAt == nil else {
                throw ServerError.conflict("Already withdrawn from this study")
            }
            guard let study = try await Study.find(enrollment.$study.id, on: transaction) else {
                throw ServerError.notFound("Study not found")
            }
            enrollment.stateVersion = try await self.consentRepository.advanceEnrollmentVersion(
                id: enrollmentId, expectedVersion: enrollment.stateVersion, on: transaction
            )
            enrollment.withdrawnAt = Date()
            try await enrollment.save(on: transaction)
            try await AuditRepository.recordMutation(AuditEvent(
                context: actor.auditContext,
                action: .enrollmentWithdrawn,
                scope: .study(studyID: enrollment.$study.id, groupID: study.$group.id),
                target: .init(id: enrollmentId, version: String(enrollment.stateVersion))
            ), on: transaction)
            return enrollment
        }
    }
}
