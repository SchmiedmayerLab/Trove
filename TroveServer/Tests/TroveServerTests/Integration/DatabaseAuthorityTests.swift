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
import Synchronization
import Testing
@testable import TroveServer
import Vapor


@Suite("Database Authority", .timeLimit(.minutes(1)))
struct DatabaseAuthorityTests {
    private enum FixtureFailure: Error, Equatable {
        case expected
    }

    @Test(arguments: [170011, 180006], ["2.29.2", "2.29.3", "2.30.0"])
    func supportedEnginePairsAreAccepted(serverVersion: Int, extensionVersion: String) throws {
        try DatabaseConfiguration.validatePrerequisites(
            serverVersion: serverVersion,
            extensionVersion: extensionVersion,
            preloadLibraries: "pg_stat_statements, timescaledb"
        )
    }

    @Test(arguments: [
        (160000, "2.29.2", "timescaledb"),
        (190000, "2.29.2", "timescaledb"),
        (180006, "2.28.0", "timescaledb"),
        (180006, "2.29.1", "timescaledb"),
        (180006, "3.0.0", "timescaledb"),
        (180006, "2.29", "timescaledb"),
        (180006, "2..29.2", "timescaledb"),
        (180006, "2.29.9999999999999999999999", "timescaledb"),
        (180006, "2.29.2-dev", "timescaledb"),
        (180006, "2.29.2", ""),
        (180006, "2.29.2", "not_timescaledb")
    ])
    func unsupportedPrerequisitesAreRejected(serverVersion: Int, extensionVersion: String, preloadLibraries: String) {
        #expect(throws: Abort.self) {
            try DatabaseConfiguration.validatePrerequisites(
                serverVersion: serverVersion,
                extensionVersion: extensionVersion,
                preloadLibraries: preloadLibraries
            )
        }
    }

    @Test
    func missingExtensionIsRejected() {
        #expect(throws: Abort.self) {
            try DatabaseConfiguration.validatePrerequisites(serverVersion: 180006, extensionVersion: nil, preloadLibraries: "timescaledb")
        }
    }

    @Test
    func inMemoryConfigurationRegistersOnlyTheAuthority() async throws {
        let app = try await Application.make(.testing)
        do {
            try DatabaseConfiguration.inMemory.configure(for: app)
            #expect(app.databases.ids() == [.psql])
            try await DatabaseConfiguration.inMemory.validatePrerequisites(for: app)
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test
    func prerequisiteValidationNeverInstallsAnAbsentExtension() async throws {
        let app = try await TestApp.makeApplication()
        do {
            try await TestDatabase.configure(for: app)
            let sql = try #require(app.db as? any SQLDatabase)
            if sql.dialect.name == "postgresql" {
                // This test owns a fresh, unmigrated database; RESTRICT prevents accidental dependent-data removal.
                try await sql.raw("DROP EXTENSION timescaledb RESTRICT").run()
                await #expect(throws: Abort.self) {
                    try await DatabaseConfiguration.postgres.validatePrerequisites(for: app)
                }
                let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM pg_extension WHERE extname = 'timescaledb'").first())
                #expect(try row.decode(column: "count", as: Int.self) == 0)
            } else {
                // SQLite remains an explicit local fixture, never a production fallback.
                #expect(sql.dialect.name == "sqlite")
                try await DatabaseConfiguration.inMemory.validatePrerequisites(for: app)
            }
        } catch {
            do {
                try await TestDatabase.shutdown(app)
            } catch {
                app.logger.error("Isolated test database cleanup failed")
            }
            throw error
        }
        try await TestDatabase.shutdown(app)
    }

    @Test(arguments: [false, true])
    func testDatabaseIsRemovedAfterBodyCompletesOrThrows(bodyThrows: Bool) async throws {
        let directory = Mutex<URL?>(nil)
        let operation: @Sendable () async throws -> Void = {
            try await TestApp.withApp(token: .none) { app, _ in
                let ownedDirectory = TestDatabase.sqliteDirectory(for: app)
                directory.withLock { $0 = ownedDirectory }
                if let ownedDirectory {
                    // Migrations have opened the database, not merely registered a pool.
                    #expect(FileManager.default.fileExists(atPath: ownedDirectory.appendingPathComponent("authority.sqlite3").path))
                } else {
                    #expect(Environment.get("TROVE_TEST_POSTGRES_PORT") != nil)
                }
                if bodyThrows {
                    throw FixtureFailure.expected
                }
            }
        }
        if bodyThrows {
            await #expect(throws: FixtureFailure.expected) {
                try await operation()
            }
        } else {
            try await operation()
        }
        if let ownedDirectory = directory.withLock({ $0 }) {
            #expect(!FileManager.default.fileExists(atPath: ownedDirectory.path))
        }
    }

    @Test
    func freshSchemaHasOneCompleteInitializationHistory() async throws {
        try await TestApp.withApp { app, _ in
            #expect(!app.databases.ids().contains(DatabaseID(string: "timescale")))
            let sql = try #require(app.db as? any SQLDatabase)
            let before = try await migrationNames(on: sql)
            #expect(before == TestDatabase.expectedMigrationNames)
            try await app.autoMigrate()
            #expect(try await migrationNames(on: sql) == before)
            #expect(try await sql.raw("SELECT COUNT(*) AS count FROM participants").first()?.decode(column: "count", as: Int.self) == 0)
        }
    }

    private func migrationNames(on sql: any SQLDatabase) async throws -> [String] {
        try await sql.raw("SELECT name FROM _fluent_migrations ORDER BY name").all().map {
            try $0.decode(column: "name", as: String.self)
        }
    }
}
