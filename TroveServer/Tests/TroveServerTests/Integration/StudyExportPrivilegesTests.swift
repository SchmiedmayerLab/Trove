// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import SQLKit
import Testing
@testable import TroveServer
import Vapor


@Suite(.enabled(if: Environment.get("TROVE_TEST_POSTGRES_PORT") != nil, "Requires an isolated PostgreSQL test database"))
struct StudyExportPrivilegesTests {
    /// The export grant of `grant-runtime.sql`.
    private static func grantExports(_ fixture: DatabaseRuntimePrivilegesTests.RuntimeFixture) async throws {
        try await fixture.admin.raw("GRANT SELECT, INSERT ON public.study_export_jobs, public.study_export_files TO \(ident: fixture.role)").run()
    }

    @Test
    func productionExportGrantsAreAccepted() async throws {
        try await DatabaseRuntimePrivilegesTests.withRuntime { fixture in
            try await Self.grantExports(fixture)
            try await DatabaseRuntimePrivileges.validate(on: fixture.database)
            let sql = try #require(fixture.database as? any SQLDatabase)
            for table in ["study_export_jobs", "study_export_files"] {
                await #expect(throws: (any Error).self) { try await sql.raw("DELETE FROM \(ident: table) WHERE false").run() }
                await #expect(throws: (any Error).self) { try await sql.raw("UPDATE \(ident: table) SET id = id WHERE false").run() }
            }
        }
    }

    @Test(arguments: [
        "UPDATE ON public.study_export_jobs", "DELETE ON public.study_export_jobs", "TRUNCATE ON public.study_export_jobs",
        "UPDATE ON public.study_export_files", "DELETE ON public.study_export_files", "TRUNCATE ON public.study_export_files"
    ])
    func excessiveExportPrivilegesAreRejected(grant: String) async throws {
        try await DatabaseRuntimePrivilegesTests.withRuntime { fixture in
            try await Self.grantExports(fixture)
            try await fixture.admin.raw("GRANT \(unsafeRaw: grant) TO \(ident: fixture.role)").run()
            await #expect(throws: (any Error).self) { try await DatabaseRuntimePrivileges.validate(on: fixture.database) }
        }
    }
}
