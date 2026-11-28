// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import SQLKit


/// Records the outcome of an open occurrence in its projection.
///
/// The occurrence keeps its identity and moves to a new change version in the enrollment's task stream, so a
/// delta returns it with its outcome instead of removing it.
enum TaskOutcomeChange {
    static func apply(
        task: String,
        expectedVersion: Int64,
        version: Int64,
        store: TaskOccurrenceStore,
        change: (inout TaskOccurrenceStore.Item) -> Void
    ) async throws {
        guard
            let row = try await store.sql.raw(
                """
                SELECT projection FROM task_occurrences
                WHERE id = \(bind: task) AND enrollment_id = \(bind: store.enrollmentID)
                  AND assigned_version = \(bind: expectedVersion) AND invalidated_version IS NULL AND invalidated_at IS NULL
                """
            )
                .first()
        else { throw ServerError.conflict("The task is no longer assigned") }
        var item = try TaskOccurrenceStore.decode(row.decode(column: "projection", as: String.self))
        guard item.id == task, item.version == expectedVersion, item.state == .assigned, version > expectedVersion else {
            throw ServerError.conflict("The task is no longer assigned")
        }
        change(&item)
        item.version = version
        let projection = try TaskOccurrenceStore.encode(item)
        let updated = try await store.sql.raw(
            """
            UPDATE task_occurrences SET assigned_version = \(bind: version), projection = \(bind: projection)
            WHERE id = \(bind: task) AND enrollment_id = \(bind: store.enrollmentID)
              AND assigned_version = \(bind: expectedVersion) AND invalidated_version IS NULL AND invalidated_at IS NULL RETURNING id
            """
        )
            .first()
        guard updated != nil else { throw ServerError.conflict("The task is no longer assigned") }
    }
}
