//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


extension StudyService {
    func auditPage(studyID: UUID, before: UUID?, limit: Int) async throws -> StudyAuditPage {
        let study = try await authorizationService.checkResearcherHasStudyAuditAccess(studyID)
        let actor = try AuthContext.checkIsResearcher()
        let page = try await AuditRepository.studyPage(
            studyID: studyID, groupID: study.$group.id, before: before, limit: limit, on: repository.database
        )
        let event = AuditEvent(
            context: actor.auditContext,
            action: .studyAuditDisclosure,
            scope: .study(studyID: studyID, groupID: study.$group.id),
            target: .init(id: studyID)
        )
        return try await AuditRepository.disclose(event, on: repository.database) { _ in page }
    }
}
