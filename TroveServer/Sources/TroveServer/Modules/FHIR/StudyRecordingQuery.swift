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


extension StudyDataQuery {
    /// Resolves a study-scoped grant using the same eligibility rules as page selection.
    /// The resulting candidate must still be fenced before storage access or disclosure.
    func recording(grantID: UUID, studyID: UUID, versions: Versions) async throws -> Page {
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        let eligible = Self.eligibleOutputs(studyID: studyID, versions: versions, on: sql)
        let rows = try await sql.raw("""
            WITH eligible AS (\(eligible))
            SELECT e.* FROM eligible e
            JOIN study_data_grants g ON g.node_id = e.node_id AND g.enrollment_id = e.enrollment_id
            JOIN clinical_recording_attachments a ON a.node_id = e.node_id
            WHERE g.id = \(bind: grantID) AND g.study_id = \(bind: studyID)
            """)
            .all()
        guard rows.count == 1, let row = rows.first else { throw ServerError.notFound("Study recording not found") }
        return try .init(outputs: [Output(row: row)], nextBefore: nil)
    }
}
