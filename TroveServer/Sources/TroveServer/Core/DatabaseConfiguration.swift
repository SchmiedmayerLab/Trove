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
import NIOSSL
import SQLKit
import Vapor


public enum DatabaseConfiguration: Sendable {
    case postgres
    case inMemory

    static func validatePrerequisites(serverVersion: Int, extensionVersion: String?, preloadLibraries: String) throws {
        let libraries = preloadLibraries.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard [17, 18].contains(serverVersion / 10000),
              extensionVersion.map(supportsTimescaleVersion) == true,
              libraries.contains("timescaledb") else {
            throw Abort(.internalServerError, reason: "PostgreSQL 17 or 18 with preloaded TimescaleDB 2.29.2 or later in major 2 is required")
        }
    }

    private static func supportsTimescaleVersion(_ raw: String) -> Bool {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 5 && $0.utf8.allSatisfy { (48...57).contains($0) } }) else {
            return false
        }
        let values = parts.compactMap { Int($0) }
        guard values.count == 3 else {
            return false
        }
        return values[0] == 2 && (values[1] > 29 || values[1] == 29 && values[2] >= 2)
    }

    public func configure(for app: Application) throws {
        switch self {
        case .inMemory:
            app.databases.use(.sqlite(.memory), as: .psql, isDefault: true)

        case .postgres:
            let transport = try app.outboundTransport
            let sqlConfig = SQLPostgresConfiguration(
                hostname: Environment.Database.host,
                port: Environment.Database.port,
                username: Environment.Database.username,
                password: Environment.Database.password,
                database: Environment.Database.name,
                tls: transport.environment == .development
                    ? .disable
                    : .require(try .init(configuration: transport.tls))
            )
            app.databases.use(.postgres(configuration: sqlConfig), as: .psql, isDefault: true)
        }
    }

    /// Operators install extensions before deployment. Serving only validates the reviewed engine pair.
    public func validatePrerequisites(for app: Application, runtime: Bool = false) async throws {
        guard case .postgres = self else {
            return
        }
        // Runtime gets only a fixed, operator-owned Boolean function, not access to all server settings.
        let preload: SQLQueryString = runtime
            ? "CASE WHEN public.trove_timescale_preloaded() THEN 'timescaledb' ELSE '' END"
            : "current_setting('shared_preload_libraries')"
        guard let sql = app.db as? any SQLDatabase,
              let row = try await sql
                .raw("""
                  SELECT current_setting('server_version_num')::integer AS server_version,
                         (SELECT extversion FROM pg_extension WHERE extname = 'timescaledb') AS extension_version,
                         \(preload) AS preload_libraries
                  """)
                .first() else {
            throw Abort(.internalServerError, reason: "Database prerequisites could not be verified")
        }
        try Self.validatePrerequisites(
            serverVersion: row.decode(column: "server_version", as: Int.self),
            extensionVersion: row.decode(column: "extension_version", as: String?.self),
            preloadLibraries: row.decode(column: "preload_libraries", as: String.self)
        )
    }
}
