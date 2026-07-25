//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Spezi


final class InvitationCodeService: Module, @unchecked Sendable {
    @Dependency(InvitationCodeRepository.self) var repository
    @Dependency(AuthorizationService.self) var authorizationService

    private static func generateCode() -> String {
        let characters = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        let raw = (0..<8).map { _ in characters.randomElement()! }
        return "\(String(raw[0..<4]))-\(String(raw[4..<8]))"
    }

    func listCodes(studyId: UUID) async throws -> [InvitationCode] {
        try await authorizationService.checkResearcherHasStudyAccess(studyId, role: .researcher)
        return try await repository.listByStudyId(studyId)
    }

    func createCodes(studyId: UUID, count: Int, expiresAt: Date?) async throws -> [InvitationCode] {
        try await authorizationService.checkResearcherHasStudyAccess(studyId, role: .researcher)

        guard (1...50).contains(count) else {
            throw ServerError.badRequest("Count must be between 1 and 50")
        }

        if let expiresAt, expiresAt <= Date() {
            throw ServerError.badRequest("Expiration date must be in the future")
        }

        var codes: [InvitationCode] = []
        var generatedCodes: Set<String> = []

        for _ in 0..<count {
            let code = try await generateUniqueCode(excluding: &generatedCodes)
            codes.append(InvitationCode(
                studyId: studyId,
                code: code,
                expiresAt: expiresAt
            ))
        }

        return try await repository.create(codes)
    }

    func deleteCode(studyId: UUID, codeId: UUID) async throws {
        try await authorizationService.checkResearcherHasStudyAccess(studyId, role: .researcher)

        guard let code = try await repository.find(id: codeId, studyId: studyId) else {
            throw ServerError.notFound(resource: "InvitationCode", identifier: codeId.uuidString)
        }

        if code.enrollment != nil {
            throw ServerError.conflict("Cannot delete an invitation code that has already been redeemed")
        }

        try await repository.delete(code)
    }

    func validateCode(_ code: String, studyId: UUID) async throws -> UUID {
        try authorizationService.checkIsParticipant()
        guard let invitationCode = try await repository.findValid(code: code, studyId: studyId) else {
            throw ServerError.badRequest("Invalid or expired invitation code")
        }
        return try invitationCode.requireId()
    }

    private func generateUniqueCode(excluding batchCodes: inout Set<String>) async throws -> String {
        for _ in 0..<10 {
            let code = Self.generateCode()
            guard batchCodes.insert(code).inserted else {
                continue
            }
            if try await repository.codeExists(code) {
                batchCodes.remove(code)
                continue
            }
            return code
        }
        throw ServerError.internalServerError("Failed to generate a unique invitation code")
    }
}
