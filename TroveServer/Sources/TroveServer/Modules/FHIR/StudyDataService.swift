//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIServer


extension StudyService {
    func dataPage(
        studyID: UUID, versions: StudyDataQuery.Versions, before: UUID?, limit: Int
    ) async throws -> Components.Schemas.StudyDataPage {
        let actor = try AuthContext.checkIsResearcher()
        _ = try await authorizationService.checkResearcherHasStudyDataAccess(studyID, actor: actor, on: repository.database)
        guard !repository.database.inTransaction else { throw AuditError.disclosureInsideTransaction }
        return try await repository.database.transaction { transaction in
            let query = StudyDataQuery(database: transaction)
            let candidates = try await query.page(studyID: studyID, versions: versions, before: before, limit: limit)
            let evidence = try await query.fence(candidates, studyID: studyID, versions: versions)
            // Admission locks participant/enrollment before inserting study-referencing grants.
            // Do not invert that order by locking the study before waiting for those owners.
            let study = try await self.repository.lockStudy(id: studyID, on: transaction)
            try await self.authorizationService.checkResearcherHasStudyDataAccess(study, actor: actor, on: transaction)
            let page = try await StudyDataExportStore(database: transaction, limits: self.exportLimits)
                .page(studyID: studyID, versions: versions, evidence: evidence)
            try Task.checkCancellation()
            try await AuditRepository.recordDisclosureIntent(.init(
                context: actor.auditContext,
                action: .studyDataDisclosure,
                scope: .study(studyID: studyID, groupID: study.$group.id),
                target: .init(id: page.id.requireId(), version: versions == .current ? "current" : "history")
            ), on: transaction)
            return page
        }
    }
}
