//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import GroveFHIRContract
import GroveProviderFHIR


/// The operator supplies this deployment-owned namespace explicitly. It cannot change after first use.
enum ProviderGlobalScopeStore {
    struct Configuration: Codable, Sendable, Equatable {
        let system: String
        let value: String

        func identifier() throws -> BusinessIdentifier {
            guard (1...512).contains(system.utf8.count), (1...256).contains(value.utf8.count) else {
                throw ProviderFailure.invalidConfiguration
            }
            return try BusinessIdentifier(system: IdentifierSystem(system), value: value)
        }
    }

    static func configure(_ configuration: Configuration, on database: any Database) async throws {
        _ = try configuration.identifier()
        try await database.transaction { transaction in
            let sql = try ProviderSQL.sql(transaction)
            try await sql.raw("""
                INSERT INTO provider_global_scopes (provider, identifier_system, identifier_value)
                VALUES ('oura', \(bind: configuration.system), \(bind: configuration.value)) ON CONFLICT (provider) DO NOTHING
                """)
                .run()
            guard try await load(on: transaction) == configuration.identifier() else { throw ProviderFailure.invalidConfiguration }
        }
    }

    static func scope(
        provider: ConnectedProvider, connection: ProviderConnection, source: SourceBinding, on database: any Database
    ) async throws -> ProviderConversionContext.Scope {
        if provider == .oura {
            return try await .global(load(on: database))
        }
        return try .account(BusinessIdentifier(
            system: IdentifierSystem(source.identifierRoot + "/provider-account"),
            value: connection.accountPseudonym.uuidString.lowercased()
        ))
    }

    static func load(on database: any Database) async throws -> BusinessIdentifier {
        guard let row = try await ProviderSQL.sql(database)
            .raw("""
                SELECT identifier_system, identifier_value FROM provider_global_scopes WHERE provider = 'oura'
                """)
            .first() else { throw ProviderFailure.invalidConfiguration }
        return try Configuration(
            system: row.decode(column: "identifier_system", as: String.self), value: row.decode(column: "identifier_value", as: String.self)
        ).identifier()
    }
}
