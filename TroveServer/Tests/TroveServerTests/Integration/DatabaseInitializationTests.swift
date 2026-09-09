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


@Suite(.enabled(if: Environment.get("TROVE_TEST_POSTGRES_PORT") != nil, "Requires a fresh isolated PostgreSQL database"))
struct DatabaseInitializationTests {
    private enum InjectedFailure: Error, Equatable { case expected }

    private struct FailingMigration: AsyncMigration {
        var name: String { "InitializationRollbackFixture" }

        func prepare(on database: any Database) async throws {
            try await database.schema("initialization_probe").id().create()
            throw InjectedFailure.expected
        }

        func revert(on database: any Database) async throws {
            try await database.schema("initialization_probe").delete()
        }
    }

    private static func absent(_ table: String, on database: any Database) async throws -> Bool {
        let sql = try #require(database as? any SQLDatabase)
        let row = try #require(try await sql.raw("SELECT to_regclass(\(bind: "public." + table)) IS NULL AS absent").first())
        return try row.decode(column: "absent", as: Bool.self)
    }

    private static func withDatabase(_ test: @escaping @Sendable (Application) async throws -> Void) async throws {
        let app = try await TestApp.makeApplication()
        do {
            try await TestDatabase.configure(for: app)
            try await test(app)
        } catch {
            try await TestDatabase.shutdown(app)
            throw error
        }
        try await TestDatabase.shutdown(app)
    }

    @Test
    func freshSchemaAndHistoryCommitOnce() async throws {
        try await Self.withDatabase { app in
            configureMigrations(for: app)
            try await DatabaseInitialization.prepare(on: app.db, migrations: app.migrations)
            let sql = try #require(app.db as? any SQLDatabase)
            let query: SQLQueryString = "SELECT jsonb_agg(to_jsonb(log) ORDER BY name)::text AS history FROM _fluent_migrations log"
            let first = try #require(try await sql.raw(query).first()).decode(column: "history", as: String.self)
            let count = try #require(try await sql.raw("SELECT count(*) AS count FROM _fluent_migrations").first())
            #expect(try count.decode(column: "count", as: Int.self) == 13)
            try await DatabaseInitialization.prepare(on: app.db, migrations: app.migrations)
            let second = try #require(try await sql.raw(query).first()).decode(column: "history", as: String.self)
            #expect(first == second)
            let events = try #require(try await sql.raw("SELECT count(*) AS count FROM clinical_events").first())
            #expect(try events.decode(column: "count", as: Int.self) == 0)
        }
    }

    @Test
    func competingConnectionCannotInitializeUntilOwnerReleases() async throws {
        try await Self.withDatabase { app in
            configureMigrations(for: app)
            try await app.db.transaction { owner in
                let sql = try #require(owner as? any SQLDatabase)
                try await sql.raw("SELECT pg_advisory_xact_lock(\(bind: DatabaseInitialization.lockKey))").run()
                await #expect(throws: DatabaseInitialization.Failure.alreadyRunning) {
                    try await DatabaseInitialization.prepare(on: app.db, migrations: app.migrations)
                }
                #expect(try await Self.absent("_fluent_migrations", on: owner))
            }
            try await DatabaseInitialization.prepare(on: app.db, migrations: app.migrations)
        }
    }

    @Test
    func failedInitializationRollsBackSchemaHistoryAndLock() async throws {
        try await Self.withDatabase { app in
            let failing = Migrations()
            failing.add(CreateGroups())
            failing.add(FailingMigration())
            await #expect(throws: InjectedFailure.expected) {
                try await DatabaseInitialization.prepare(on: app.db, migrations: failing)
            }
            #expect(try await Self.absent("initialization_probe", on: app.db))
            #expect(try await Self.absent("groups", on: app.db))
            #expect(try await Self.absent("_fluent_migrations", on: app.db))
            configureMigrations(for: app)
            try await DatabaseInitialization.prepare(on: app.db, migrations: app.migrations)
        }
    }
}
