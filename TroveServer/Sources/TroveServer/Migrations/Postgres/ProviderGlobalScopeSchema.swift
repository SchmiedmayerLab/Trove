//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import FluentPostgresDriver
import SQLKit


/// A deployment's global provider key space is retained independently of registrations and accounts.
enum ProviderGlobalScopeSchema {
    /// Provider identity scopes, query coverage and conversion instants are append-only evidence for the runtime login.
    static let appendOnlyTables = ["provider_global_scopes", "provider_query_coverage", "provider_conversion_instants"]

    static func prepare(on database: any Database) async throws {
        try await database.schema("provider_global_scopes")
            .field("provider", .string, .identifier(auto: false), .required, .sql(unsafeRaw: "CHECK (provider = 'oura')"))
            .field("identifier_system", .string, .required, .sql(unsafeRaw: "CHECK (length(identifier_system) BETWEEN 1 AND 512)"))
            .field("identifier_value", .string, .required, .sql(unsafeRaw: "CHECK (length(identifier_value) BETWEEN 1 AND 256)"))
            .create()
        try await protect(table: "provider_global_scopes", on: database)
    }

    static func protect(table: String, on database: any Database) async throws {
        let sql = try ProviderSQL.sql(database)
        if database is any PostgresDatabase {
            try await sql.raw("""
                CREATE TRIGGER \(ident: table + "_no_mutation") BEFORE UPDATE OR DELETE OR TRUNCATE
                ON \(ident: table) FOR EACH STATEMENT EXECUTE FUNCTION trove_reject_source_identity_mutation()
                """)
                .run()
        } else {
            for operation in ["UPDATE", "DELETE"] {
                try await sql.raw("""
                    CREATE TRIGGER \(ident: table + "_no_" + operation.lowercased()) BEFORE \(unsafeRaw: operation)
                    ON \(ident: table) BEGIN SELECT RAISE(ABORT, 'Provider identity scope is immutable'); END
                    """)
                    .run()
            }
        }
    }
}
