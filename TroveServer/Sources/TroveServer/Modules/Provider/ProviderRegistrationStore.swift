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


struct ProviderRegistrationStore: Sendable {
    struct Approved: Sendable {
        let configuration: ProviderRegistration
        let generation: Int64
    }

    let database: any Database

    /// Called only by operator configuration. No participant route can approve an integration.
    func configure(_ registration: ProviderRegistration, approved: Bool, audit: AuditEvent.Context) async throws {
        try registration.validate()
        let configuration = try ProviderSQL.encode(registration)
        try await database.transaction { transaction in
            let sql = try ProviderSQL.sql(transaction)
            var generation: Int64 = 1
            if let row = try await sql.raw("""
                UPDATE provider_registrations SET generation = generation WHERE id = \(bind: registration.id) RETURNING *
                """).first() {
                let existing: ProviderRegistration = try ProviderSQL.decode(row.decode(column: "configuration", as: String.self))
                guard existing.provider == registration.provider, existing.controller == registration.controller,
                      existing.region == registration.region, existing.clientID == registration.clientID else {
                    throw ProviderFailure.invalidConfiguration
                }
                if existing == registration, try row.decode(column: "approved", as: Bool.self) == approved { return }
                let previous = try row.decode(column: "generation", as: Int64.self)
                guard previous > 0, previous < Int64.max else { throw ProviderFailure.unavailable }
                generation = previous + 1
                try await sql.raw("""
                    UPDATE provider_registrations SET configuration = \(bind: configuration), approved = \(bind: approved),
                        generation = \(bind: generation), updated_at = \(bind: Date()) WHERE id = \(bind: registration.id)
                    """).run()
            } else {
                try await sql.raw("""
                    INSERT INTO provider_registrations (id, configuration, approved, generation, updated_at)
                    VALUES (\(bind: registration.id), \(bind: configuration), \(bind: approved), 1, \(bind: Date()))
                    """).run()
            }
            try await AuditRepository.recordMutation(.init(
                context: audit, action: .providerRegistrationChanged, scope: .providerRegistration(registrationID: registration.id),
                target: .init(id: registration.id, version: String(generation))
            ), on: transaction)
        }
    }

    static func requireApproved(_ id: UUID, on database: any Database, lock: Bool = false) async throws -> Approved {
        let sql = try ProviderSQL.sql(database)
        let row: (any SQLRow)?
        if lock {
            guard database.inTransaction else { throw AuditError.transactionRequired }
            row = try await sql.raw("""
                UPDATE provider_registrations SET generation = generation WHERE id = \(bind: id) AND approved = \(bind: true) RETURNING *
                """).first()
        } else {
            row = try await sql.raw("SELECT * FROM provider_registrations WHERE id = \(bind: id) AND approved = \(bind: true)").first()
        }
        guard let row else { throw ProviderFailure.fenced }
        let configuration: ProviderRegistration = try ProviderSQL.decode(row.decode(column: "configuration", as: String.self))
        try configuration.validate()
        let generation = try row.decode(column: "generation", as: Int64.self)
        guard generation > 0, configuration.id == id else { throw ProviderFailure.unavailable }
        return Approved(configuration: configuration, generation: generation)
    }
}
