//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import SQLKit
import Vapor


/// Overrides the default command after Fluent initializes; serving never runs it.
struct InitializeDatabaseCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Flag(name: "revert", help: "Unsupported: recreate disposable development databases instead.") var revert: Bool
    }

    var help: String { "Initialize the current PostgreSQL schema atomically with one operator." }

    func run(using context: CommandContext, signature: Signature) async throws {
        guard !signature.revert else { throw DatabaseInitialization.Failure.reversionUnsupported }
        guard context.console.confirm("Initialize the current schema? Use only a fresh or matching development database.") else {
            throw DatabaseInitialization.Failure.confirmationRequired
        }
        do {
            try await DatabaseInitialization.prepare(on: context.application.db, migrations: context.application.migrations)
        } catch DatabaseInitialization.Failure.alreadyRunning {
            context.console.error("Another operator is initializing this database. Retry after it finishes.")
            throw DatabaseInitialization.Failure.alreadyRunning
        }
        context.console.success("Schema initialization completed.")
    }
}


/// One authoritative database and one atomic initialization, including Fluent's history.
enum DatabaseInitialization {
    enum Failure: Error, Equatable {
        case postgresRequired
        case alreadyRunning
        case reversionUnsupported
        case confirmationRequired
    }

    static let lockKey: Int64 = 0x5472_6F76_6544_4249

    static func prepare(on database: any Database, migrations: Migrations) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            throw Failure.postgresRequired
        }
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw Failure.postgresRequired }
            try await sql.raw("SET LOCAL transaction_timeout = '120s'").run()
            try await sql.raw("SET LOCAL statement_timeout = '60s'").run()
            try await sql.raw("SET LOCAL lock_timeout = '15s'").run()
            let row = try await sql.raw("SELECT pg_try_advisory_xact_lock(\(bind: lockKey)) AS acquired").first()
            guard try row?.decode(column: "acquired", as: Bool.self) == true else {
                throw Failure.alreadyRunning
            }
            // Every registered migration belongs to this single authority. Reusing
            // app.migrator here would escape to its pool and lose the transaction.
            let migrator = Migrator(databaseFactory: { _ in transaction }, migrations: migrations, on: transaction.eventLoop)
            try await migrator.setupIfNeeded().get()
            try await migrator.prepareBatch().get()
        }
    }
}
