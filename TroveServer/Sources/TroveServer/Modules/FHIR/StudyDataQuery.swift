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


/// Internal selection of exact granted outputs. These addresses do not authorize disclosure
/// of their containing records, related resources, participant identity, or other study context.
/// The disclosure service must authorize the caller, fence current authority, project permitted
/// fields and commit its audit intent before returning any data outside the server.
struct StudyDataQuery: Sendable {
    enum Versions: Sendable {
        case current
        case history
    }

    struct Output: Sendable, Equatable {
        let nodeID: UUID
        let eventID: UUID
        let sourceID: UUID
        let enrollmentID: UUID
        let participantID: UUID
        let recordID: UUID
        let outputBindingID: UUID
        let fullURL: String
        let receivedAt: Date
        let isCurrent: Bool

        init(row: any SQLRow) throws {
            nodeID = try row.decode(column: "node_id", as: UUID.self)
            eventID = try row.decode(column: "event_id", as: UUID.self)
            sourceID = try row.decode(column: "source_id", as: UUID.self)
            enrollmentID = try row.decode(column: "enrollment_id", as: UUID.self)
            participantID = try row.decode(column: "participant_id", as: UUID.self)
            recordID = try row.decode(column: "record_id", as: UUID.self)
            outputBindingID = try row.decode(column: "output_binding_id", as: UUID.self)
            fullURL = try row.decode(column: "full_url", as: String.self)
            receivedAt = try row.decode(column: "received_at", as: Date.self)
            isCurrent = try row.decode(column: "is_current", as: Int.self) == 1
        }
    }

    struct Page: Sendable {
        let outputs: [Output]
        let nextBefore: UUID?
    }

    static let maximumPageOutputs = 1024

    let database: any Database

    /// Live keyset pagination, not a frozen dataset. A cursor must still be eligible in this
    /// exact study/version view; withdrawal, retraction or supersession can require a fresh page.
    /// Newly attributed old events may also require restarting from the first page.
    /// Page limits count records; a complete workout is never split across pages.
    func page(studyID: UUID, versions: Versions = .current, before: UUID? = nil, limit: Int = 50) async throws -> Page {
        guard (1...100).contains(limit) else { throw ServerError.badRequest("Study data page limit must be between 1 and 100") }
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        let eligible = Self.eligibleOutputs(studyID: studyID, versions: versions, on: sql)
        var boundary: SQLQueryString = ""
        if let before {
            let anchor = try await sql.raw("""
                WITH eligible AS (\(eligible)) SELECT node_id FROM eligible WHERE node_id = \(bind: before)
                """)
                .first()
            guard anchor != nil else { throw ServerError.badRequest("Invalid study data page cursor") }
            // Compare stored timestamps in SQL; converting the cursor timestamp to Date can lose precision.
            boundary = """
                WHERE (received_at, event_id) < (SELECT received_at, event_id FROM eligible WHERE node_id = \(bind: before))
                """
        }
        let groups = try await sql.raw("""
            WITH eligible AS (\(eligible)) SELECT event_id, received_at, COUNT(*) AS output_count FROM eligible \(boundary)
            GROUP BY event_id, received_at ORDER BY received_at DESC, event_id DESC LIMIT \(bind: limit + 1)
            """)
            .all()
        var eventIDs: [UUID] = [], outputCount = 0
        for group in groups.prefix(limit) {
            let count = try group.decode(column: "output_count", as: Int.self)
            guard (1...512).contains(count) else { throw StudyProjectionJSON.Failure.outputTooLarge }
            guard outputCount + count <= Self.maximumPageOutputs else { break }
            outputCount += count
            eventIDs.append(try group.decode(column: "event_id", as: UUID.self))
        }
        guard !eventIDs.isEmpty else {
            return .init(outputs: [], nextBefore: nil)
        }
        let rows = try await sql.raw("""
            WITH eligible AS (\(eligible)) SELECT * FROM eligible WHERE event_id IN (\(binds: eventIDs))
            ORDER BY received_at DESC, event_id DESC, node_id DESC LIMIT \(bind: Self.maximumPageOutputs + 1)
            """)
            .all()
        guard rows.count == outputCount else { throw ServerError.conflict("Study data changed; restart from the first page") }
        let outputs = try rows.map { try Output(row: $0) }
        return .init(outputs: outputs, nextBefore: groups.count > eventIDs.count ? outputs.last?.nodeID : nil)
    }
}


extension StudyDataQuery {
    /// One row per output even when several exact consent revisions grant it. The winning
    /// record version is selected across custody before study filtering: never substitute an
    /// older authorized version when the actual current version has no grant for this study.
    static func eligibleOutputs(studyID: UUID, versions: Versions, on sql: any SQLDatabase) -> SQLQueryString {
        let current = ClinicalRecordStore.currentPredicate(on: sql)
        let selection: SQLQueryString = versions == .current ? current : "1 = 1"
        return """
            SELECT DISTINCT n.id AS node_id, n.event_id, n.source_id, e.id AS enrollment_id, e.participant_id,
                f.record_id, f.output_binding_id, n.full_url, event.received_at,
                CASE WHEN \(current) THEN 1 ELSE 0 END AS is_current
            FROM study_data_grants g
            JOIN enrollments e ON e.id = g.enrollment_id AND e.study_id = g.study_id
            JOIN enrollment_consents c ON c.id = g.consent_id AND c.enrollment_id = e.id AND c.revision = g.revision
            JOIN published_studies p ON p.id = g.publication_id AND p.study_id = g.study_id AND p.revision = g.revision
            JOIN clinical_event_nodes n ON n.id = g.node_id
            JOIN clinical_point_facts f ON f.node_id = n.id
            JOIN clinical_record_events r ON r.event_id = n.event_id
            JOIN clinical_events event ON event.id = n.event_id
            JOIN source_bindings s ON s.id = n.source_id AND s.participant_id = e.participant_id
            WHERE g.study_id = \(bind: studyID) AND e.withdrawn_at IS NULL
                AND NOT \(ClinicalRecordStore.retracted("f.record_id"))
                AND \(selection) AND \(ClinicalGraphStore.disclosurePredicate)
            """
    }
}
