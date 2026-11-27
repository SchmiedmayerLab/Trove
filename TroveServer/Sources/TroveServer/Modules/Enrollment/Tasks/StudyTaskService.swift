//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import SQLKit
import TroveAPIServer


extension StudyService {
    private static func taskItem(_ row: any SQLRow) throws -> Components.Schemas.ParticipantTaskOccurrence {
        let projection = try row.decode(column: "projection", as: String.self)
        let item = try TaskOccurrenceStore.decode(projection)
        guard try item.id == row.decode(column: "id", as: String.self),
              try UUID(uuidString: item.enrollmentId) == row.decode(column: "enrollment_id", as: UUID.self),
              try UUID(uuidString: item.publicationId) == row.decode(column: "publication_id", as: UUID.self) else {
            throw ServerError.internalServerError("Task assignment identity is inconsistent")
        }
        return item
    }

    func taskPage(studyID: UUID, after: String?, limit: Int) async throws -> Components.Schemas.StudyTaskPage {
        let actor = try AuthContext.checkIsResearcher()
        _ = try await authorizationService.checkResearcherHasStudyDataAccess(studyID, actor: actor, on: repository.database)
        guard (1...100).contains(limit) else { throw ServerError.badRequest("Invalid task page size") }
        guard !repository.database.inTransaction else { throw AuditError.disclosureInsideTransaction }
        return try await repository.database.transaction { transaction in
            let study = try await self.repository.lockStudy(id: studyID, on: transaction)
            try await self.authorizationService.checkResearcherHasStudyDataAccess(study, actor: actor, on: transaction)
            guard let sql = transaction as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
            let scope: SQLQueryString = """
                FROM task_occurrences t
                JOIN enrollments e ON e.id = t.enrollment_id
                JOIN published_studies p ON p.id = t.publication_id AND p.study_id = e.study_id
                WHERE e.study_id = \(bind: studyID)
                """
            if let after {
                guard after.utf8.count == 64, after.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      !(try await sql.raw("SELECT t.id \(scope) AND t.id = \(bind: after)").all()).isEmpty else {
                    throw ServerError.badRequest("Invalid study task cursor")
                }
            }
            let rows = try await sql.raw("""
                SELECT t.id, t.enrollment_id, t.publication_id, t.projection \(scope)
                  AND t.id > \(bind: after ?? "") AND t.invalidated_version IS NULL AND t.invalidated_at IS NULL
                  AND e.withdrawn_at IS NULL AND (e.ends_at IS NULL OR e.ends_at > \(bind: Date()))
                ORDER BY t.id LIMIT \(bind: limit + 1)
                """)
                .all()
            let items = try rows.prefix(limit).map(Self.taskItem)
            try await AuditRepository.recordDisclosureIntent(.init(
                context: actor.auditContext,
                action: .tasksDisclosure,
                scope: .study(studyID: studyID, groupID: study.$group.id),
                target: .init(id: studyID)
            ), on: transaction)
            return .init(studyId: studyID.uuidString, items: items, nextAfter: rows.count > limit ? items.last?.id : nil)
        }
    }
}
