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
import Logging


final class StudyService: Module, @unchecked Sendable {
    @Dependency(StudyRepository.self) var repository
    @Dependency(AuthorizationService.self) var authorizationService

    func getStudy(id: UUID) async throws -> Study {
        try await readDraft(id: id) { study, _ in study }
    }

    func createStudy(groupId: UUID, study: Study) async throws -> Study {
        try await authorizationService.checkResearcherHasGroupAccess(groupId, role: .admin)
        let context = try AuthContext.checkIsResearcher().auditContext
        return try await repository.database.transaction { transaction in
            try await study.save(on: transaction)
            try await AuditRepository.recordMutation(AuditEvent(
                context: context,
                action: .studyDraftCreated,
                scope: .study(studyID: study.requireId(), groupID: groupId),
                target: .init(id: study.requireId(), version: study.draftRevision.uuidString)
            ), on: transaction)
            return study
        }
    }

    func listStudies(groupId: UUID) async throws -> [Study] {
        try await authorizationService.checkResearcherHasGroupAccess(groupId, role: .researcher)
        return try await repository.listAll(groupId: groupId)
    }

    func patchStudy(id: UUID, expectedRevision: UUID, patch: StudyPatch) async throws -> Study {
        try await editDraft(id: id, expectedRevision: expectedRevision) { study, _ in
            try study.apply(patch)
            return study
        }
    }

    func deleteStudy(id: UUID, expectedRevision: UUID) async throws {
        let authorized = try await authorizationService.checkResearcherHasStudyAccess(id, role: .admin)
        let actor = try AuthContext.checkIsResearcher()
        try await repository.database.transaction { transaction in
            _ = try await self.repository.lockDraft(id: id, expectedRevision: expectedRevision, on: transaction)
            guard let study = try await self.repository.deleteUnusedDraft(
                id: id, expectedGroupID: authorized.$group.id, on: transaction
            ) else {
                throw ServerError.notFound(resource: "Study", identifier: id.uuidString)
            }
            let event = AuditEvent(
                context: actor.auditContext,
                action: .studyDraftDeleted,
                scope: .study(studyID: id, groupID: study.$group.id),
                target: .init(id: id)
            )
            try await AuditRepository.recordMutation(event, on: transaction)
        }
    }
}
