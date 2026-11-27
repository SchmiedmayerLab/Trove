// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Fluent
import Foundation


/// Server time for task admission. Tests bind a fixed instant to check windows, cutoffs and DST days.
enum TaskClock {
    @TaskLocal static var now: @Sendable () -> Date = { Date() }

    /// Runs a database transaction with the caller's clock. The driver runs the closure in a new task,
    /// which does not inherit task-local values.
    static func transaction<Result: Sendable>(
        on database: any Database,
        _ body: @escaping @Sendable (any Database) async throws -> Result
    ) async throws -> Result {
        let clock = now
        return try await database.transaction { transaction in
            try await $now.withValue(clock) { try await body(transaction) }
        }
    }
}
