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


struct ClinicalAttributionReceipt: Sendable, Equatable {
    let commandID: UUID
    let eventID: UUID
    let targetIntentSHA256: String
    let acceptedAt: Date
    let authorizedOutputCount: Int
}


/// Adds exact-version purposes, never a second payload or a change to the original event intent.
struct ClinicalAttributionStore: Sendable {
    let database: any Database

    func attribute(eventID: UUID, sourceID: UUID, commandID: UUID, targets: [ClinicalEventTarget]) async throws -> ClinicalAttributionReceipt {
        let context = try AuthContext.checkIsParticipant()
        guard !targets.isEmpty else { throw ServerError.badRequest("Attribution requires explicit consent targets") }
        let intent = try ClinicalEventIntent(targets: targets)
        return try await database.transaction { transaction in
            let source = try await ClinicalEventStore(database: transaction).lockSourceOwner(
                sourceID: sourceID, context: context, on: transaction, requireActive: false
            )
            guard let sql = transaction as? any SQLDatabase else { throw ServerError.unexpectedError }
            if let receipt = try await self.replay(commandID: commandID, sourceID: sourceID, eventID: eventID, intent: intent, on: sql) {
                return receipt
            }
            guard source.revokedAt == nil, source.kind == .participantApp else {
                throw ServerError.conflict("Source binding is not active")
            }
            let grants = ClinicalGrantStore(database: transaction, source: source, context: context, acceptedAt: Date())
            return try await self.insert(commandID: commandID, eventID: eventID, intent: intent, grants: grants)
        }
    }

    private func insert(
        commandID: UUID, eventID: UUID, intent: ClinicalEventIntent, grants: ClinicalGrantStore
    ) async throws -> ClinicalAttributionReceipt {
        let sourceID = grants.source.id
        let transaction = grants.database
        guard let sql = transaction as? any SQLDatabase else { throw ServerError.unexpectedError }
        let event = try await sql.raw("SELECT id FROM clinical_events WHERE id = \(bind: eventID) AND source_id = \(bind: sourceID)").first()
        guard event != nil else {
            throw ServerError.notFound("Clinical event not found")
        }
        let rows = try await sql.raw("""
            SELECT f.node_id, n.full_url, f.profile, f.effective_at
            FROM clinical_point_facts f JOIN clinical_event_nodes n ON n.id = f.node_id
            WHERE f.event_id = \(bind: eventID) AND f.source_id = \(bind: sourceID)
            """)
            .all()
        let outputs = try rows.map {
            try ClinicalGrantStore.Output(
                fullURL: $0.decode(column: "full_url", as: String.self),
                profile: $0.decode(column: "profile", as: String.self),
                effectiveAt: $0.decode(column: "effective_at", as: Date.self)
            )
        }
        let authorities = try await grants.authorities(outputs: outputs, intent: intent, requireCustodyCoverage: false)
        for row in rows {
            let fullURL = try row.decode(column: "full_url", as: String.self)
            for authority in authorities where authority.outputs.contains(fullURL) {
                _ = try await grants.insert(authority, nodeID: row.decode(column: "node_id", as: UUID.self))
            }
        }
        return try await record(commandID: commandID, eventID: eventID, intent: intent, grants: grants)
    }

    private func record(
        commandID: UUID, eventID: UUID, intent: ClinicalEventIntent, grants: ClinicalGrantStore
    ) async throws -> ClinicalAttributionReceipt {
        guard let sql = grants.database as? any SQLDatabase else { throw ServerError.unexpectedError }
        let sourceID = grants.source.id
        let count = intent.targets.reduce(0) { $0 + $1.outputFullURLs.count }
        try await sql.raw("""
            INSERT INTO clinical_attribution_commands (id, source_id, command_id, event_id, target_intent, accepted_at, authorized_output_count)
            VALUES (\(bind: UUID()), \(bind: sourceID), \(bind: commandID), \(bind: eventID),
                \(bind: intent.serialized), \(bind: grants.acceptedAt), \(bind: count))
            """)
            .run()
        try await AuditRepository.recordMutation(.init(
            context: grants.context.auditContext,
            action: .clinicalEventAttributed,
            scope: .participantSource(participantID: grants.source.participantID, sourceBindingID: sourceID),
            target: .init(id: commandID)
        ), on: grants.database)
        guard let receipt = try await self.replay(commandID: commandID, sourceID: sourceID, eventID: eventID, intent: intent, on: sql) else {
            throw ServerError.unexpectedError
        }
        return receipt
    }

    private func replay(
        commandID: UUID, sourceID: UUID, eventID: UUID, intent: ClinicalEventIntent, on sql: any SQLDatabase
    ) async throws -> ClinicalAttributionReceipt? {
        guard let row = try await sql.raw("""
            SELECT event_id, target_intent, accepted_at, authorized_output_count FROM clinical_attribution_commands
            WHERE source_id = \(bind: sourceID) AND command_id = \(bind: commandID)
            """)
            .first() else { return nil }
        guard try row.decode(column: "event_id", as: UUID.self) == eventID,
              try row.decode(column: "target_intent", as: String.self) == intent.serialized else {
            throw ServerError.conflict("Attribution command already exists with different event or targets")
        }
        return try .init(
            commandID: commandID,
            eventID: eventID,
            targetIntentSHA256: intent.sha256,
            acceptedAt: row.decode(column: "accepted_at", as: Date.self),
            authorizedOutputCount: row.decode(column: "authorized_output_count", as: Int.self)
        )
    }
}
