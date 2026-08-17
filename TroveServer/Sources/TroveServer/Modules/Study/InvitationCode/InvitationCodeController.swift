//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIServer


extension Controller {
    func getStudiesStudyIdInvitationCodes(
        _ input: Operations.GetStudiesStudyIdInvitationCodes.Input
    ) async throws -> Operations.GetStudiesStudyIdInvitationCodes.Output {
        let studyId = try input.path.studyId.requireId()
        let codes = try await invitationCodeService.listCodes(studyId: studyId)
        return .ok(.init(body: .json(try codes.map { try .init($0) })))
    }

    func postStudiesStudyIdInvitationCodes(
        _ input: Operations.PostStudiesStudyIdInvitationCodes.Input
    ) async throws -> Operations.PostStudiesStudyIdInvitationCodes.Output {
        let studyId = try input.path.studyId.requireId()
        guard case .json(let body) = input.body else {
            throw ServerError.jsonBodyRequired
        }
        let codes = try await invitationCodeService.createCodes(
            studyId: studyId,
            count: body.count,
            expiresAt: body.expiresAt
        )
        return .created(.init(body: .json(try codes.map { try .init($0) })))
    }

    func deleteStudiesStudyIdInvitationCodesCodeId(
        _ input: Operations.DeleteStudiesStudyIdInvitationCodesCodeId.Input
    ) async throws -> Operations.DeleteStudiesStudyIdInvitationCodesCodeId.Output {
        let studyId = try input.path.studyId.requireId()
        let codeId = try input.path.codeId.requireId()
        try await invitationCodeService.deleteCode(studyId: studyId, codeId: codeId)
        return .noContent(.init())
    }
}
