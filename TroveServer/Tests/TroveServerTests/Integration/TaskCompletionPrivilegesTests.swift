// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import SQLKit
import Testing
@testable import TroveServer
import Vapor


@Suite(.enabled(if: Environment.get("TROVE_TEST_POSTGRES_PORT") != nil, "Requires an isolated PostgreSQL test database"))
struct TaskCompletionPrivilegesTests {
    /// The task grants of `grant-runtime.sql`.
    private static func grantTasks(_ fixture: DatabaseRuntimePrivilegesTests.RuntimeFixture) async throws {
        try await fixture.admin.raw(
            "GRANT SELECT, INSERT ON public.task_sessions, public.task_completions, public.task_failures, public.task_excusals TO \(ident: fixture.role)"
        )
            .run()
        try await DatabaseRuntimePrivilegesTests.grantTaskOccurrences(role: fixture.role, on: fixture.admin)
    }

    @Test
    func productionTaskGrantsAreAccepted() async throws {
        try await DatabaseRuntimePrivilegesTests.withRuntime { fixture in
            try await Self.grantTasks(fixture)
            try await DatabaseRuntimePrivileges.validate(on: fixture.database)
            let sql = try #require(fixture.database as? any SQLDatabase)
            for table in ["task_sessions", "task_completions", "task_failures", "task_excusals"] {
                await #expect(throws: (any Error).self) { try await sql.raw("DELETE FROM \(ident: table) WHERE false").run() }
                await #expect(throws: (any Error).self) { try await sql.raw("UPDATE \(ident: table) SET id = id WHERE false").run() }
            }
            await #expect(throws: (any Error).self) { try await sql.raw("UPDATE task_occurrences SET due_at = due_at WHERE false").run() }
        }
    }

    @Test(arguments: [
        "UPDATE (due_at) ON public.task_occurrences", "UPDATE (publication_id) ON public.task_occurrences",
        "DELETE ON public.task_occurrences", "UPDATE ON public.task_sessions", "DELETE ON public.task_sessions",
        "UPDATE (receipt) ON public.task_completions", "DELETE ON public.task_completions", "TRUNCATE ON public.task_completions",
        "UPDATE ON public.task_failures", "DELETE ON public.task_failures", "UPDATE ON public.task_excusals", "DELETE ON public.task_excusals"
    ])
    func excessiveTaskPrivilegesAreRejected(grant: String) async throws {
        try await DatabaseRuntimePrivilegesTests.withRuntime { fixture in
            try await Self.grantTasks(fixture)
            try await fixture.admin.raw("GRANT \(unsafeRaw: grant) TO \(ident: fixture.role)").run()
            await #expect(throws: (any Error).self) { try await DatabaseRuntimePrivileges.validate(on: fixture.database) }
        }
    }
}
