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


/// Language approvals are append-only: the runtime inserts them and may only record their revocation.
extension DatabaseRuntimePrivilegesTests {
    static func grantLanguageApprovals(role: String, on sql: any SQLDatabase) async throws {
        try await sql.raw("GRANT SELECT, INSERT ON public.questionnaire_language_approvals TO \(ident: role)").run()
        try await sql.raw("""
            GRANT UPDATE (revoked_at, revoked_by_issuer, revoked_by_subject) ON public.questionnaire_language_approvals TO \(ident: role)
            """)
            .run()
    }

    @Test
    func runtimeAppendsLanguageApprovalsAndRecordsOnlyTheirRevocation() async throws {
        try await Self.withRuntime { fixture in
            let sql = try #require(fixture.database as? any SQLDatabase)
            let permissions = try #require(try await sql.raw("""
                SELECT has_table_privilege(current_user, 'questionnaire_language_approvals', 'SELECT')
                    AND has_table_privilege(current_user, 'questionnaire_language_approvals', 'INSERT') AS allowed
                """)
                .first())
            #expect(try permissions.decode(column: "allowed", as: Bool.self))
            try await sql.raw("""
                UPDATE questionnaire_language_approvals
                SET revoked_at = CURRENT_TIMESTAMP, revoked_by_issuer = 'issuer', revoked_by_subject = 'subject' WHERE false
                """)
                .run()
            for statement in [
                "UPDATE questionnaire_language_approvals SET sha256 = sha256 WHERE false",
                "DELETE FROM questionnaire_language_approvals WHERE false", "TRUNCATE questionnaire_language_approvals"
            ] {
                await #expect {
                    try await sql.raw(SQLQueryString(statement)).run()
                } throws: { ($0 as? PSQLError)?.serverInfo?[.sqlState] == "42501" }
            }
        }
    }

    @Test(arguments: [
        ("UPDATE ON public.questionnaire_language_approvals", false),
        ("UPDATE (sha256) ON public.questionnaire_language_approvals", false),
        ("DELETE ON public.questionnaire_language_approvals", false),
        ("TRUNCATE ON public.questionnaire_language_approvals", false),
        ("INSERT ON public.questionnaire_language_approvals", true),
        ("UPDATE (revoked_by_issuer) ON public.questionnaire_language_approvals", true),
        ("UPDATE (revoked_by_subject) ON public.questionnaire_language_approvals", true)
    ])
    func excessiveLanguageApprovalPrivilegesAreRejected(grant: String, delegated: Bool) async throws {
        try await Self.withRuntime { fixture in
            let option = delegated ? " WITH GRANT OPTION" : ""
            try await fixture.admin.raw("GRANT \(unsafeRaw: grant) TO \(ident: fixture.role)\(unsafeRaw: option)").run()
            await Self.expectRejected(on: fixture.database)
        }
    }
}
