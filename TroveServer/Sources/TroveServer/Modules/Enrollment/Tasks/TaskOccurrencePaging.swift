//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SQLKit
import TroveAPITypes


extension TaskOccurrenceStore {
    struct Position {
        let after: Int64
        let upper: Int64?
        let snapshot: Bool
    }

    static let projectionVersion = 1

    func position(cursor: UUID?, active: Bool, now: Date) async throws -> Position {
        try await sql.raw(
            """
            DELETE FROM task_sync_cursors WHERE enrollment_id = \(bind: enrollmentID) AND expires_at <= \(bind: now)
            """
        )
            .run()
        guard let cursor else {
            return .init(after: 0, upper: nil, snapshot: true)
        }
        let expired = ServerError(status: .gone, title: "Task cursor expired", detail: "Request a fresh snapshot")
        guard
            let row = try await sql.raw(
                """
                SELECT after_version, upper_version, snapshot, active, enrollment_version FROM task_sync_cursors
                WHERE id = \(bind: cursor) AND enrollment_id = \(bind: enrollmentID) AND participant_id = \(bind: participantID)
                  AND projection_version = \(bind: Self.projectionVersion) AND expires_at > \(bind: now)
                """
            )
                .first()
        else { throw expired }
        let upper = try row.decode(column: "upper_version", as: Int64?.self)
        if upper != nil {
            let originalActive = try row.decode(column: "active", as: Bool.self)
            let originalVersion = try row.decode(column: "enrollment_version", as: Int64.self)
            guard active == originalActive, enrollment.stateVersion == originalVersion else { throw expired }
        }
        return try .init(
            after: row.decode(column: "after_version", as: Int64.self),
            upper: upper,
            snapshot: row.decode(column: "snapshot", as: Bool.self)
        )
    }

    func page(
        _ position: Position,
        watermark: Int64,
        limit: Int,
        active: Bool,
        now: Date
    ) async throws -> Components.Schemas.ParticipantTaskPage {
        let upper = position.upper ?? watermark
        let rows: [any SQLRow]
        if let base = enrollment.taskClosureBase {
            rows = position.snapshot ? [] : try await closedRemovals(after: position.after, base: base, limit: limit + 1)
        } else {
            rows = try await changes(position, upper: upper, limit: limit)
        }
        var items = [Item]()
        var invalidated = [String]()
        var after = position.after
        for row in rows.prefix(limit) {
            after = try row.decode(column: "version", as: Int64.self)
            if let payload = try row.decode(column: "projection", as: String?.self) {
                items.append(try TaskOccurrenceStore.decode(payload))
            } else {
                invalidated.append(try row.decode(column: "id", as: String.self))
            }
        }
        let more = rows.count > limit
        let next = Position(after: more ? after : upper, upper: more ? upper : nil, snapshot: more && position.snapshot)
        let reference = try await save(next, active: active, now: now)
        return .init(
            snapshotVersion: upper,
            items: items,
            invalidated: invalidated,
            nextCursor: more ? reference : nil,
            checkpoint: more ? nil : reference
        )
    }

    private func changes(_ position: Position, upper: Int64, limit: Int) async throws -> [any SQLRow] {
        let query: SQLQueryString = """
            SELECT id, assigned_version AS version, projection FROM task_occurrences
            WHERE enrollment_id = \(bind: enrollmentID) AND assigned_version > \(bind: position.after)
                AND assigned_version <= \(bind: upper) AND (invalidated_version IS NULL OR invalidated_version > \(bind: upper))
            """
        let removals: SQLQueryString =
            position.snapshot
            ? ""
            : """
             UNION ALL SELECT id, invalidated_version AS version, NULL AS projection FROM task_occurrences
             WHERE enrollment_id = \(bind: enrollmentID) AND invalidated_version > \(bind: position.after) AND invalidated_version <= \(bind: upper)
            """
        return try await sql.raw(
            """
            SELECT * FROM (\(query) \(removals)) changes ORDER BY version LIMIT \(bind: limit + 1)
            """
        )
            .all()
    }

    private func closedRemovals(after: Int64, base: Int64, limit: Int) async throws -> [any SQLRow] {
        var rows: [any SQLRow] = []
        if after < base {
            rows = try await sql.raw(
                """
                SELECT id, invalidated_version AS version, NULL AS projection FROM task_occurrences
                WHERE enrollment_id = \(bind: enrollmentID) AND invalidated_version > \(bind: after)
                ORDER BY invalidated_version LIMIT \(bind: limit)
                """
            )
                .all()
        }
        guard rows.count < limit, after < base * 2 else {
            return rows
        }
        // A partial index on active assignments supports seeking directly to each page.
        let next = try await sql.raw(
            """
            SELECT id, assigned_version + \(bind: base) AS version, NULL AS projection FROM task_occurrences
            WHERE enrollment_id = \(bind: enrollmentID) AND invalidated_version IS NULL
              AND assigned_version > \(bind: max(0, after - base))
            ORDER BY assigned_version LIMIT \(bind: limit - rows.count)
            """
        )
            .all()
        return rows + next
    }

    private func save(_ position: Position, active: Bool, now: Date) async throws -> String {
        let next = UUID()
        let expiry = now.addingTimeInterval(86_400)
        try await sql.raw(
            """
            INSERT INTO task_sync_cursors
                (id, enrollment_id, participant_id, projection_version, enrollment_version, active,
                 after_version, upper_version, snapshot, expires_at)
            VALUES (\(bind: next), \(bind: enrollmentID), \(bind: participantID), \(bind: Self.projectionVersion), \(bind: enrollment.stateVersion),
                \(bind: active), \(bind: position.after), \(bind: position.upper), \(bind: position.snapshot), \(bind: expiry))
            """
        )
            .run()
        return next.uuidString.lowercased()
    }
}
