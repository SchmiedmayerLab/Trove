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


/// Centralized authorization. Every guard the application performs lives here so
/// permission rules can be audited in one place.
///
/// Naming convention:
/// - `checkIs<Role>` for realm-role predicates (researcher, participant).
/// - `check<Role>Has<Resource>Access` for resource-aware checks. Role identifies the
///   actor; resource identifies what is being accessed.
/// - All guards throw on failure. When a guard fetches a resource as part of the
///   check, that resource is returned so callers do not have to fetch it again.
final class AuthorizationService: Module, @unchecked Sendable {
    @Dependency(ProfileRepository.self) var profileRepository
    @Dependency(EnrollmentRepository.self) var enrollmentRepository
    @Dependency(StudyRepository.self) var studyRepository
    @Dependency(GroupRepository.self) var groupRepository

    @discardableResult
    func checkIsResearcher() throws -> AuthContext {
        try AuthContext.checkIsResearcher()
    }

    @discardableResult
    func checkIsParticipant() throws -> AuthContext {
        try AuthContext.checkIsParticipant()
    }

    @discardableResult
    func checkResearcherHasGroupAccess(_ groupId: UUID, role: AuthContext.GroupRole) async throws -> Group {
        try AuthContext.checkIsResearcher()

        guard let group = try await groupRepository.find(id: groupId) else {
            throw ServerError.notFound(resource: "Group", identifier: groupId.uuidString)
        }

        try AuthContext.checkHasAccess(groupName: group.name, role: role)
        return group
    }

    @discardableResult
    func checkResearcherHasStudyAccess(_ studyId: UUID, role: AuthContext.GroupRole) async throws -> Study {
        try AuthContext.checkIsResearcher()

        guard let study = try await studyRepository.find(id: studyId) else {
            throw ServerError.notFound(resource: "Study", identifier: studyId.uuidString)
        }
        // Authorize the group belonging to this exact study snapshot, not a group
        // from an earlier lookup followed by a second potentially changed study.
        try await checkResearcherHasGroupAccess(study.$group.id, role: role)
        return study
    }

    /// Audit visibility is an explicit capability in addition to group administration.
    func checkResearcherHasStudyAuditAccess(_ studyId: UUID) async throws -> Study {
        try AuthContext.checkIsResearcher()
        guard let study = try await studyRepository.find(id: studyId) else {
            throw ServerError.notFound(resource: "Study", identifier: studyId.uuidString)
        }
        let group = try await checkResearcherHasGroupAccess(study.$group.id, role: .admin)
        try AuthContext.checkHasAuditAccess(groupName: group.name)
        return study
    }

    /// Verifies the caller owns the enrollment with the given id. Returns the enrollment.
    func checkParticipantHasEnrollmentAccess(id enrollmentId: UUID) async throws -> Enrollment {
        let participantId = try await currentParticipantId()

        guard let enrollment = try await enrollmentRepository.find(id: enrollmentId) else {
            throw ServerError.notFound(resource: "Enrollment", identifier: enrollmentId.uuidString)
        }

        guard enrollment.$participant.id == participantId else {
            throw ServerError.notFound(resource: "Enrollment", identifier: enrollmentId.uuidString)
        }

        return enrollment
    }

    /// Verifies the caller has an enrollment in the given study. Returns the enrollment.
    func checkParticipantHasEnrollmentAccess(studyId: UUID) async throws -> Enrollment {
        let participantId = try await currentParticipantId()

        guard let enrollment = try await enrollmentRepository.find(participantId: participantId, studyId: studyId) else {
            throw ServerError.notFound(resource: "Enrollment", identifier: studyId.uuidString)
        }

        return enrollment
    }

    private func currentParticipantId() async throws -> UUID {
        let context = try AuthContext.checkIsParticipant()
        guard let participant = try await profileRepository.findByIdentity(issuer: context.issuer, subject: context.subject) else {
            throw ServerError.notFound(resource: "Participant", identifier: context.subject)
        }
        return try participant.requireId()
    }
}
