//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import SQLKit
import Testing
@testable import TroveServer
import Vapor


@Suite(.enabled(if: Environment.get("TROVE_TEST_POSTGRES_PORT") != nil, "Requires an isolated PostgreSQL test database"))
struct ProviderCollectionPrivilegesTests {
    @Test(arguments: ProviderGlobalScopeSchema.appendOnlyTables)
    func runtimeCanAppendButCannotRewriteDelegateOrHideProviderEvidence(table: String) async throws {
        try await DatabaseRuntimePrivilegesTests.withRuntime { fixture in
            try await DatabaseRuntimePrivileges.validate(on: fixture.database)
            let sql = try #require(fixture.database as? any SQLDatabase)
            let permissions = try #require(try await sql.raw("""
                SELECT has_table_privilege(current_user, \(bind: table), 'SELECT')
                    AND has_table_privilege(current_user, \(bind: table), 'INSERT') AS allowed
                """)
                .first())
            #expect(try permissions.decode(column: "allowed", as: Bool.self))
            await #expect(throws: (any Error).self) { try await sql.raw("DELETE FROM \(ident: table) WHERE false").run() }
            await #expect(throws: (any Error).self) { try await sql.raw("TRUNCATE \(ident: table)").run() }
            for grant in ["UPDATE", "DELETE", "TRUNCATE"] {
                try await fixture.admin.raw("GRANT \(unsafeRaw: grant) ON \(ident: table) TO \(ident: fixture.role)").run()
                await #expect(throws: (any Error).self) { try await DatabaseRuntimePrivileges.validate(on: fixture.database) }
                try await fixture.admin.raw("REVOKE \(unsafeRaw: grant) ON \(ident: table) FROM \(ident: fixture.role)").run()
            }
            try await fixture.admin.raw("GRANT INSERT ON \(ident: table) TO \(ident: fixture.role) WITH GRANT OPTION").run()
            await #expect(throws: (any Error).self) { try await DatabaseRuntimePrivileges.validate(on: fixture.database) }
            try await fixture.admin.raw("REVOKE GRANT OPTION FOR INSERT ON \(ident: table) FROM \(ident: fixture.role)").run()
            try await DatabaseRuntimePrivileges.validate(on: fixture.database)
            try await fixture.admin.raw("ALTER TABLE \(ident: table) RENAME TO provider_evidence_test_hidden").run()
            await #expect(throws: (any Error).self) { try await DatabaseRuntimePrivileges.validate(on: fixture.database) }
            try await fixture.admin.raw("ALTER TABLE provider_evidence_test_hidden RENAME TO \(ident: table)").run()
        }
    }
}


extension ProviderCollectionPrivilegesTests {
    /// The provider grants of `grant-runtime.sql`: no provider row is deletable and the append-only evidence is never updated.
    static func grantRuntime(role: String, on sql: any SQLDatabase) async throws {
        for grant in [
            """
            SELECT, INSERT, UPDATE ON public.provider_registrations, public.provider_connections, public.provider_link_intents,
                public.provider_checkpoints, public.provider_worker_states
            """,
            """
            SELECT, INSERT ON public.provider_staged_records, public.provider_query_coverage, public.provider_conversion_instants,
                public.provider_global_scopes
            """,
            "UPDATE (event_id) ON public.provider_staged_records",
            "SELECT, UPDATE ON public.provider_dispatch_budgets"
        ] {
            try await sql.raw("GRANT \(unsafeRaw: grant) TO \(ident: role)").run()
        }
    }
}
