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


extension AuditRepository {
    /// Internal read primitive; the service authorizes both identifiers before calling.
    static func studyPage(
        studyID: UUID, groupID: UUID, before: UUID?, limit: Int, on database: any Database
    ) async throws -> StudyAuditPage {
        guard (1...100).contains(limit) else { throw ServerError.badRequest("Audit page limit must be between 1 and 100") }
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        let scope: SQLQueryString = "scope_kind = 'study' AND study_id = \(bind: studyID) AND group_id = \(bind: groupID)"
        var boundary: SQLQueryString = ""
        if let before {
            let anchor = try await sql.raw("SELECT id FROM audit_events WHERE \(scope) AND id = \(bind: before)").first()
            guard anchor != nil else {
                throw ServerError.badRequest("Invalid audit page cursor")
            }
            // Compare inside the database; a Date round trip can lose cursor precision.
            boundary = """
                AND (occurred_at, id) < (SELECT occurred_at, id FROM audit_events WHERE \(scope) AND id = \(bind: before))
                """
        }
        let rows = try await sql.raw("""
            SELECT id, occurred_at, actor_issuer, actor_subject, initiator_issuer, initiator_subject,
                   executing_client_id, delegation_id,
                   action, target_id, target_version, outcome, correlation_id, application_revision
            FROM audit_events WHERE \(scope) \(boundary)
            ORDER BY occurred_at DESC, id DESC LIMIT \(bind: limit + 1)
            """)
            .all()
        let records = try rows.prefix(limit).map { try StudyAuditRecord(row: $0) }
        return .init(studyID: studyID, records: records, nextBefore: rows.count > limit ? records.last?.id : nil)
    }
}
