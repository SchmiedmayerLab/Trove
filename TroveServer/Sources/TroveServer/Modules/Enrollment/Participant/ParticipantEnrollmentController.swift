//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import OpenAPIRuntime
import TroveAPIServer


extension Controller {
    func postParticipantStudiesStudyIdEnrollments(
        _ input: Operations.PostParticipantStudiesStudyIdEnrollments.Input
    ) async throws -> Operations.PostParticipantStudiesStudyIdEnrollments.Output {
        let studyId = try input.path.studyId.requireId()
        let invitationCode: String?
        if case .json(let body) = input.body {
            invitationCode = body.invitationCode
        } else {
            invitationCode = nil
        }
        let enrollment = try await participantEnrollmentService.enroll(studyId: studyId, invitationCode: invitationCode)
        return .created(.init(body: .json(try .init(enrollment))))
    }

    func getParticipantEnrollments(
        _ input: Operations.GetParticipantEnrollments.Input
    ) async throws -> Operations.GetParticipantEnrollments.Output {
        let enrollments = try await participantEnrollmentService.listParticipantEnrollments()
        return .ok(.init(body: .json(try enrollments.map { try .init($0) })))
    }

    func postParticipantEnrollmentsEnrollmentIdWithdraw(
        _ input: Operations.PostParticipantEnrollmentsEnrollmentIdWithdraw.Input
    ) async throws -> Operations.PostParticipantEnrollmentsEnrollmentIdWithdraw.Output {
        let enrollmentId = try input.path.enrollmentId.requireId()
        let enrollment = try await participantEnrollmentService.withdraw(enrollmentId: enrollmentId)
        return .ok(.init(body: .json(try .init(enrollment))))
    }

    func getParticipantStudiesStudyIdRevisionBundle(
        _ input: Operations.GetParticipantStudiesStudyIdRevisionBundle.Input
    ) async throws -> Operations.GetParticipantStudiesStudyIdRevisionBundle.Output {
        let studyId = try input.path.studyId.requireId()
        let revision = input.path.revision
        let data = try await publishedStudyService.participantBundle(studyId: studyId, revision: revision)
        return .ok(.init(
            headers: .init(contentDisposition: "attachment; filename=\"\(studyId)-\(revision).studybundle.zip\""),
            body: .applicationZip(HTTPBody(data))
        ))
    }
}
