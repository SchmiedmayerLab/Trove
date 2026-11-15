//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import SQLKit


enum ProviderWorkerSchema {
    static func prepare(on database: any Database) async throws {
        try await database.schema("provider_worker_states")
            .field("connection_id", .uuid, .identifier(auto: false), .references("provider_connections", "id", onDelete: .restrict))
            .field("last_source_token", .string, .sql(unsafeRaw: "CHECK (last_source_token IS NULL OR length(last_source_token) BETWEEN 1 AND 255)"))
            .field("outcome", .string, .required, .sql(unsafeRaw: "CHECK (outcome IN ('scheduled', 'accepted', 'idle', 'deferred', 'failed'))"))
            .field("failure_count", .int, .required, .sql(unsafeRaw: "CHECK (failure_count BETWEEN 0 AND 16)"))
            .field("failure_kind", .string, .sql(unsafeRaw:
                "CHECK (failure_kind IS NULL OR failure_kind IN ('transient', 'capacity', 'source', 'authority'))"
            ))
            .create()
        try await database.schema("provider_dispatch_budgets")
            .field("provider", .string, .identifier(auto: false))
            .field("not_before", .datetime, .required)
            .create()
        let sql = try ProviderSQL.sql(database)
        for provider in ConnectedProvider.allCases {
            try await sql.raw("""
                INSERT INTO provider_dispatch_budgets (provider, not_before) VALUES (\(bind: provider.rawValue), \(bind: Date(timeIntervalSince1970: 0)))
                """).run()
        }
    }
}
