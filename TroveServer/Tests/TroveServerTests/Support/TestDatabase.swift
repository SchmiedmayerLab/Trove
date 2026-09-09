//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import Foundation
import SQLKit
@testable import TroveServer
import Vapor


/// Optional real-store lane. Only freshly generated databases on a loopback test server
/// are created or dropped; production database environment variables are never read.
enum TestDatabase {
    private struct CreatedDatabases: StorageKey {
        typealias Value = [String]
    }

    private struct SQLiteDirectory: StorageKey {
        typealias Value = URL
    }

    private static let adminID = DatabaseID(string: "test-admin")

    static func configure(for app: Application) async throws {
        guard let rawPort = Environment.get("TROVE_TEST_POSTGRES_PORT") else {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trove-test-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            app.storage[SQLiteDirectory.self] = directory
            app.databases.use(.sqlite(.file(directory.appendingPathComponent("authority.sqlite3").path)), as: .psql)
            return
        }
        guard let port = Int(rawPort), (1024...65535).contains(port) else {
            throw Abort(.internalServerError, reason: "Invalid isolated test database port")
        }
        func configuration(database: String) -> SQLPostgresConfiguration {
            .init(
                hostname: "127.0.0.1",
                port: port,
                username: "trove_test",
                password: "trove_test",
                database: database,
                tls: .disable
            )
        }
        app.databases.use(.postgres(configuration: configuration(database: "postgres")), as: adminID, isDefault: false)
        guard let admin = app.db(adminID) as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "PostgreSQL test driver unavailable")
        }
        let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let name = "trove_test_\(identifier)_core"
        try await admin.raw("CREATE DATABASE \(ident: name)").run()
        app.storage[CreatedDatabases.self] = [name]
        // Two leases on the application's single loop preserve real concurrent-transaction tests.
        app.databases.use(
            .postgres(configuration: configuration(database: name), maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true
        )
        guard let core = app.db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Timescale test driver unavailable")
        }
        // Test setup is the operator only for this invocation's freshly created database.
        try await core.raw("CREATE EXTENSION IF NOT EXISTS timescaledb").run()
        try await DatabaseConfiguration.postgres.validatePrerequisites(for: app)
    }

    static func sqliteDirectory(for app: Application) -> URL? {
        app.storage[SQLiteDirectory.self]
    }

    /// Stops the application and all of its pools, then opens its existing disposable
    /// database in a new application. No schema creation, data copying, or reseeding occurs.
    static func withRestartedApplication(
        _ original: Application,
        _ test: @escaping @Sendable (Application) async throws -> Void
    ) async throws {
        let directory = original.storage[SQLiteDirectory.self]
        let names = original.storage[CreatedDatabases.self]
        let restarted = try await TestApp.makeApplication()
        do {
            if let directory {
                restarted.databases.use(.sqlite(.file(directory.appendingPathComponent("authority.sqlite3").path)), as: .psql)
                restarted.storage[SQLiteDirectory.self] = directory
            } else if let names, names.count == 1, let name = names.first,
                      let port = Environment.get("TROVE_TEST_POSTGRES_PORT").flatMap(Int.init), (1024...65535).contains(port) {
                func configuration(_ database: String) -> SQLPostgresConfiguration {
                    .init(hostname: "127.0.0.1", port: port, username: "trove_test", password: "trove_test", database: database, tls: .disable)
                }
                restarted.databases.use(.postgres(configuration: configuration(name), maxConnectionsPerEventLoop: 2), as: .psql)
                restarted.databases.use(.postgres(configuration: configuration("postgres")), as: adminID, isDefault: false)
                restarted.storage[CreatedDatabases.self] = names
            } else {
                throw Abort(.internalServerError, reason: "No owned disposable database to reopen")
            }
            // Transfer cleanup ownership before stopping the old application's pools.
            original.storage[SQLiteDirectory.self] = nil
            original.storage[CreatedDatabases.self] = nil
            try await original.asyncShutdown()
            try await test(restarted)
        } catch {
            do {
                try await shutdown(restarted)
            } catch {
                restarted.logger.error("Restarted test application cleanup failed; disposable data may remain")
            }
            throw error
        }
        try await shutdown(restarted)
    }

    /// PostgreSQL removal needs the live admin pool; SQLite removal needs every pool closed.
    static func shutdown(_ app: Application) async throws {
        let directory = sqliteDirectory(for: app)
        var cleanupError: (any Error)?
        do {
            try await dropPostgresDatabases(for: app)
        } catch {
            cleanupError = error
        }
        do {
            if !app.didShutdown {
                try await app.asyncShutdown()
            }
            // Capture before shutdown clears storage. Remove only this invocation's
            // directory, including SQLite journal files, never driver-wide paths.
            if let directory {
                try FileManager.default.removeItem(at: directory)
            }
        } catch {
            if cleanupError != nil {
                app.logger.error("Additional isolated test database shutdown failure")
            } else {
                cleanupError = error
            }
        }
        if let cleanupError {
            throw cleanupError
        }
    }

    private static func dropPostgresDatabases(for app: Application) async throws {
        guard let names = app.storage[CreatedDatabases.self], !names.isEmpty else {
            return
        }
        guard let admin = app.db(adminID) as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "PostgreSQL test cleanup unavailable")
        }
        // Tests have completed. FORCE closes this application's idle pools before removal.
        // Targets are only the exact names successfully created by this invocation.
        for name in names {
            try await admin.raw("DROP DATABASE IF EXISTS \(ident: name) WITH (FORCE)").run()
        }
        app.storage[CreatedDatabases.self] = nil
    }
}
