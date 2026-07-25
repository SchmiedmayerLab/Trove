//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import NIOSSL
import Vapor


public enum DatabaseConfiguration: Sendable {
    case postgres
    case inMemory

    public func configure(for app: Application) throws {
        switch self {
        case .inMemory:
            app.databases.use(.sqlite(.memory), as: .psql, isDefault: true)
            app.databases.use(.sqlite(.memory), as: .timescale, isDefault: false)

        case .postgres:
            let sqlConfig = SQLPostgresConfiguration(
                hostname: Environment.Database.host,
                port: Environment.Database.port,
                username: Environment.Database.username,
                password: Environment.Database.password,
                database: Environment.Database.name,
                tls: Environment.appEnvironment == .development
                    ? .disable
                    : .require(try .init(configuration: .clientDefault))
            )
            app.databases.use(.postgres(configuration: sqlConfig), as: .psql, isDefault: true)

            let timescaleConfig = SQLPostgresConfiguration(
                hostname: Environment.Timescale.host,
                port: Environment.Timescale.port,
                username: Environment.Timescale.username,
                password: Environment.Timescale.password,
                database: Environment.Timescale.name,
                tls: Environment.appEnvironment == .development
                    ? .disable
                    : .require(try .init(configuration: .clientDefault))
            )
            app.databases.use(.postgres(configuration: timescaleConfig), as: .timescale, isDefault: false)
        }
    }
}
