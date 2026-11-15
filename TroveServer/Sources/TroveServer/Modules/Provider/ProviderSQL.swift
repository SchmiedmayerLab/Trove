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


enum ProviderSQL {
    static func sql(_ database: any Database) throws -> any SQLDatabase {
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        return sql
    }

    static func encode(_ value: some Encodable, maximumBytes: Int = 131_072) throws -> String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let bytes = try encoder.encode(value)
            guard bytes.count <= maximumBytes, let string = String(data: bytes, encoding: .utf8) else { throw ProviderFailure.capacityExceeded }
            return string
        } catch let failure as ProviderFailure { throw failure } catch { throw ProviderFailure.invalidPayload }
    }

    static func decode<T: Decodable>(_ value: String, maximumBytes: Int = 131_072) throws -> T {
        guard (1...maximumBytes).contains(value.utf8.count) else { throw ProviderFailure.unavailable }
        do { return try JSONDecoder().decode(T.self, from: Data(value.utf8)) } catch { throw ProviderFailure.unavailable }
    }

    static func lockParticipant(_ id: UUID, on database: any Database) async throws {
        guard database.inTransaction else { throw AuditError.transactionRequired }
        let row = try await sql(database).raw("UPDATE participants SET id = id WHERE id = \(bind: id) RETURNING id").first()
        guard row != nil else { throw ProviderFailure.fenced }
    }

    static func connection(_ id: UUID, on database: any Database) async throws -> ProviderConnection {
        guard let row = try await sql(database).raw("SELECT * FROM provider_connections WHERE id = \(bind: id)").first() else {
            throw ProviderFailure.fenced
        }
        return try ProviderConnection(row: row)
    }
}
