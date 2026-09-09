//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import SQLKit
import Testing
@testable import TroveServer
import Vapor


struct TestDatabasePoolTests {
    @Test
    func applicationUsesOneLoopWithoutOwningItsLifetime() async throws {
        let app = try await TestApp.makeApplication()
        let loop = app.eventLoopGroup.next()
        #expect(app.eventLoopGroup.next() === loop)
        try await app.asyncShutdown()
        #expect(try await loop.submit { 42 }.get() == 42)
    }

    @Test(.enabled(if: Environment.get("TROVE_TEST_POSTGRES_PORT") != nil))
    func independentApplicationsKeepBoundedConcurrentDatabaseLeases() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await TestApp.withApp { app, _ in
                        try await app.db.withConnection { first in
                            let firstPID = try await Self.connectionPID(first)
                            try await app.db.withConnection { second in
                                #expect(try await Self.connectionPID(second) != firstPID)
                                let sql = try #require(second as? any SQLDatabase)
                                let row = try #require(try await sql.raw("""
                                    SELECT COUNT(*) AS count FROM pg_stat_activity
                                    WHERE datname = current_database() AND backend_type = 'client backend'
                                    """)
                                    .first())
                                #expect(try row.decode(column: "count", as: Int.self) == 2)
                            }
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
    }
}


extension TestDatabasePoolTests {
    private static func connectionPID(_ database: any Database) async throws -> Int {
        let sql = try #require(database as? any SQLDatabase)
        let row = try #require(try await sql.raw("SELECT pg_backend_pid() AS pid").first())
        return try row.decode(column: "pid", as: Int.self)
    }
}
