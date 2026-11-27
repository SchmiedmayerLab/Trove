//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import FluentPostgresDriver
import Foundation
import SQLKit
import Testing
@testable import TroveServer


/// Task occurrences are append-only: the runtime inserts them and may only record their invalidation.
extension DatabaseRuntimePrivilegesTests {
    static func grantTaskOccurrences(role: String, on sql: any SQLDatabase) async throws {
        try await sql.raw("GRANT SELECT, INSERT ON public.task_occurrences TO \(ident: role)").run()
        try await sql.raw("GRANT UPDATE (invalidated_version, invalidated_at) ON public.task_occurrences TO \(ident: role)").run()
    }

    @Test
    func runtimeAppendsTaskOccurrencesAndRecordsOnlyTheirInvalidation() async throws {
        try await Self.withRuntime { fixture in
            let sql = try #require(fixture.database as? any SQLDatabase)
            let permissions = try #require(try await sql.raw("""
                SELECT has_table_privilege(current_user, 'task_occurrences', 'SELECT')
                    AND has_table_privilege(current_user, 'task_occurrences', 'INSERT') AS allowed
                """)
                .first())
            #expect(try permissions.decode(column: "allowed", as: Bool.self))
            try await sql.raw("UPDATE task_occurrences SET invalidated_version = 2, invalidated_at = CURRENT_TIMESTAMP WHERE false").run()
            for statement in [
                "UPDATE task_occurrences SET due_at = due_at WHERE false",
                "DELETE FROM task_occurrences WHERE false", "TRUNCATE task_occurrences"
            ] {
                await #expect {
                    try await sql.raw(SQLQueryString(statement)).run()
                } throws: { ($0 as? PSQLError)?.serverInfo?[.sqlState] == "42501" }
            }
        }
    }

    @Test(arguments: [
        ("UPDATE ON public.task_occurrences", false),
        ("UPDATE (due_at) ON public.task_occurrences", false),
        ("DELETE ON public.task_occurrences", false),
        ("TRUNCATE ON public.task_occurrences", false),
        ("INSERT ON public.task_occurrences", true),
        ("UPDATE (invalidated_version) ON public.task_occurrences", true),
        ("UPDATE (invalidated_at) ON public.task_occurrences", true)
    ])
    func excessiveTaskOccurrencePrivilegesAreRejected(grant: String, delegated: Bool) async throws {
        try await Self.withRuntime { fixture in
            let option = delegated ? " WITH GRANT OPTION" : ""
            try await fixture.admin.raw("GRANT \(unsafeRaw: grant) TO \(ident: fixture.role)\(unsafeRaw: option)").run()
            await Self.expectRejected(on: fixture.database)
        }
    }
}
