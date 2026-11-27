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


/// Internal evidence captured under the caller's transaction. It is usable only while that
/// transaction holds its locks, and is not a substitute for researcher authorization or audit.
struct StudyDataFence: Sendable {
    struct Grant: Sendable {
        let id: UUID
        let nodeID: UUID
        let enrollmentID: UUID
        let consentID: UUID
        let publicationID: UUID
        let revision: Int

        init(row: any SQLRow) throws {
            id = try row.decode(column: "id", as: UUID.self)
            nodeID = try row.decode(column: "node_id", as: UUID.self)
            enrollmentID = try row.decode(column: "enrollment_id", as: UUID.self)
            consentID = try row.decode(column: "consent_id", as: UUID.self)
            publicationID = try row.decode(column: "publication_id", as: UUID.self)
            revision = try row.decode(column: "revision", as: Int.self)
        }
    }

    struct EnrollmentSnapshot: Sendable {
        let id: UUID
        let endsAt: Date?
    }

    let page: StudyDataQuery.Page
    let grants: [Grant]
    let enrollments: [EnrollmentSnapshot]
}


extension StudyDataQuery {
    private static var changedPage: ServerError {
        .conflict("Study data changed; restart from the first page")
    }

    /// Never refill a captured page after locking: replacement candidates could have owners
    /// outside the lock set. Changed eligibility requires a new page and transaction instead.
    /// Keep these locks through projection and committed disclosure intent before releasing data.
    func fence(_ page: Page, studyID: UUID, versions: Versions = .current, tasks: [TaskExportMember] = []) async throws -> StudyDataFence {
        guard database.inTransaction else { throw AuditError.transactionRequired }
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        let ids = page.outputs.map(\.nodeID)
        guard ids.count <= Self.maximumPageOutputs, Set(ids).count == ids.count,
              page.nextBefore == nil || page.nextBefore == ids.last else { throw ServerError.unexpectedError }
        guard !ids.isEmpty || !tasks.isEmpty else {
            return .init(page: page, grants: [], enrollments: [])
        }

        let repository = ConsentRepository(database: database)
        // Admission, attribution and source lifecycle all lock participant before enrollment.
        for id in Set(page.outputs.map(\.participantID) + tasks.map(\.participant)).sorted(by: { $0.uuidString < $1.uuidString }) {
            _ = try await repository.lockParticipant(id: id, on: database)
        }
        var enrollments: [StudyDataFence.EnrollmentSnapshot] = []
        for id in Set(page.outputs.map(\.enrollmentID) + tasks.map(\.enrollment)).sorted(by: { $0.uuidString < $1.uuidString }) {
            let enrollment = try await repository.lockEnrollment(id: id, on: database)
            guard enrollment.$study.id == studyID, enrollment.withdrawnAt == nil,
                  tasks.filter({ $0.enrollment == id }).allSatisfy({ $0.participant == enrollment.$participant.id }),
                  page.outputs.filter({ $0.enrollmentID == id }).allSatisfy({ $0.participantID == enrollment.$participant.id }) else {
                throw tasks.contains(where: { $0.enrollment == id }) ? ServerError.forbidden : Self.changedPage
            }
            enrollments.append(.init(id: id, endsAt: enrollment.endsAt))
        }
        guard !ids.isEmpty else {
            return .init(page: page, grants: [], enrollments: enrollments)
        }
        let eligible = Self.eligibleOutputs(studyID: studyID, versions: versions, on: sql)
        let rows = try await sql.raw("""
            WITH eligible AS (\(eligible)) SELECT * FROM eligible WHERE node_id IN (\(binds: ids))
            ORDER BY received_at DESC, event_id DESC, node_id DESC
            """)
            .all()
        let current = try rows.map { try Output(row: $0) }
        guard current == page.outputs else { throw Self.changedPage }
        let grants = try await exactGrants(studyID: studyID, ids: ids, eligible: eligible, on: sql)
        guard Set(grants.map(\.nodeID)) == Set(ids) else { throw Self.changedPage }
        return .init(page: page, grants: grants, enrollments: enrollments)
    }

    private func exactGrants(
        studyID: UUID, ids: [UUID], eligible: SQLQueryString, on sql: any SQLDatabase
    ) async throws -> [StudyDataFence.Grant] {
        let rows = try await sql.raw("""
            WITH eligible AS (\(eligible))
            SELECT g.id, g.node_id, g.enrollment_id, g.consent_id, g.publication_id, g.revision
            FROM study_data_grants g
            JOIN eligible e ON e.node_id = g.node_id AND e.enrollment_id = g.enrollment_id
            JOIN enrollment_consents c ON c.id = g.consent_id AND c.enrollment_id = e.enrollment_id AND c.revision = g.revision
            JOIN published_studies p ON p.id = g.publication_id AND p.study_id = g.study_id AND p.revision = g.revision
            WHERE g.study_id = \(bind: studyID) AND g.node_id IN (\(binds: ids))
            ORDER BY g.node_id, g.revision, g.id LIMIT 8193
            """)
            .all()
        guard rows.count <= 8192 else { throw StudyProjectionJSON.Failure.outputTooLarge }
        return try rows.map { try StudyDataFence.Grant(row: $0) }
    }
}
