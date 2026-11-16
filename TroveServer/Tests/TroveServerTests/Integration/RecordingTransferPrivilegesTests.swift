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
struct RecordingTransferPrivilegesTests {
    @Test(arguments: CreateRecordingTransfers.tables)
    func runtimeCanAppendButCannotRewriteDelegateOrHideTransferEvidence(table: String) async throws {
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
            try await fixture.admin.raw("GRANT UPDATE ON \(ident: table) TO \(ident: fixture.role)").run()
            await #expect(throws: (any Error).self) { try await DatabaseRuntimePrivileges.validate(on: fixture.database) }
            try await fixture.admin.raw("REVOKE UPDATE ON \(ident: table) FROM \(ident: fixture.role)").run()
            try await fixture.admin.raw("GRANT SELECT ON \(ident: table) TO \(ident: fixture.role) WITH GRANT OPTION").run()
            await #expect(throws: (any Error).self) { try await DatabaseRuntimePrivileges.validate(on: fixture.database) }
            try await fixture.admin.raw("REVOKE GRANT OPTION FOR SELECT ON \(ident: table) FROM \(ident: fixture.role)").run()
            try await DatabaseRuntimePrivileges.validate(on: fixture.database)
            try await fixture.admin.raw("ALTER TABLE \(ident: table) RENAME TO recording_transfer_test_hidden").run()
            await #expect(throws: (any Error).self) { try await DatabaseRuntimePrivileges.validate(on: fixture.database) }
            try await fixture.admin.raw("ALTER TABLE recording_transfer_test_hidden RENAME TO \(ident: table)").run()
        }
    }
}
