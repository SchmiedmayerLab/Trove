//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import Grove
import SQLKit


final class SourceBindingService: Module, Sendable {
    let database: any Database

    init(database: any Database) {
        self.database = database
    }

    func find(id: UUID) async throws -> SourceBinding {
        let context = try AuthContext.checkIsParticipant()
        let participant = try await ProfileRepository(database: database).findByIdentity(issuer: context.issuer, subject: context.subject)
        guard let participant else {
            throw ServerError.notFound("Source binding not found")
        }
        return try await find(id: id, participantID: participant.requireID(), on: database)
    }

    func revoke(id: UUID) async throws -> SourceBinding {
        let context = try AuthContext.checkIsParticipant()
        return try await database.transaction { transaction in
            let participantID = try await Self.lockParticipant(context, on: transaction)
            let binding = try await self.find(id: id, participantID: participantID, on: transaction)
            guard binding.revokedAt == nil else {
                return binding
            }
            let sql = try self.sql(on: transaction)
            try await sql.raw("""
                UPDATE source_bindings SET revoked_at = \(bind: max(Date(), binding.createdAt))
                WHERE id = \(bind: id) AND participant_id = \(bind: participantID)
                """)
                .run()
            try await self.audit(.sourceRevoked, id: id, participantID: participantID, context: context, on: transaction)
            return try await self.find(id: id, participantID: participantID, on: transaction)
        }
    }

    private func find(id: UUID, participantID: UUID, on database: any Database) async throws -> SourceBinding {
        let row = try await sql(on: database).raw("""
            SELECT * FROM source_bindings WHERE id = \(bind: id) AND participant_id = \(bind: participantID)
            """)
            .first()
        guard let row else { throw ServerError.notFound("Source binding not found") }
        let source = try SourceBinding(row: row)
        guard source.kind == .participantApp else { throw ServerError.notFound("Native source binding not found") }
        return source
    }

    private func sql(on database: any Database) throws -> any SQLDatabase {
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        return sql
    }

    private func audit(
        _ action: AuditEvent.Action, id: UUID, participantID: UUID, context: AuthContext, on transaction: any Database
    ) async throws {
        try await AuditRepository.recordMutation(.init(
            context: context.auditContext,
            action: action,
            scope: .participantSource(participantID: participantID, sourceBindingID: id),
            target: .init(id: id)
        ), on: transaction)
    }
}


extension SourceBindingService {
    static func lockParticipant(_ context: AuthContext, on database: any Database) async throws -> UUID {
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        // Lock before reading the registration nonce. All source mutations for this
        // verified owner share the same transaction and serialize on this row.
        let row = try await sql.raw("""
            UPDATE participants SET id = id
            WHERE identity_provider_issuer = \(bind: context.issuer) AND identity_provider_id = \(bind: context.subject)
            RETURNING id
            """)
            .first()
        guard let row else { throw ServerError.notFound("Participant profile not found") }
        return try row.decode(column: "id", as: UUID.self)
    }
}
