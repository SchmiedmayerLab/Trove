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


/// Appends on the caller's explicit transaction; never silently opens another connection.
enum AuditRepository {
    @discardableResult
    static func recordMutation(_ event: AuditEvent, on transaction: any Database) async throws -> AuditReceipt {
        guard transaction.inTransaction else {
            throw AuditError.transactionRequired
        }
        guard !event.action.isDisclosure else {
            throw AuditError.invalidAction
        }
        return try await append(event, outcome: "succeeded", on: transaction)
    }

    /// The caller must finish authorization before entering this gate. Receipt means intent,
    /// not successful delivery: an interrupted response must not be reported as delivered.
    static func disclose<Value: Sendable>(
        _ event: AuditEvent,
        on database: any Database,
        release: @Sendable (AuditReceipt) async throws -> Value
    ) async throws -> Value {
        // An inner transaction may not commit independently of an outer one.
        guard !database.inTransaction else {
            throw AuditError.disclosureInsideTransaction
        }
        guard event.action.isDisclosure else {
            throw AuditError.invalidAction
        }
        let receipt = try await database.transaction { transaction in
            try await append(event, outcome: "disclosure_intent", on: transaction)
        }
        return try await release(receipt)
    }

    private static func append(_ event: AuditEvent, outcome: String, on database: any Database) async throws -> AuditReceipt {
        try event.validate()
        guard let sql = database as? any SQLDatabase else {
            throw AuditError.unsupportedDatabase
        }
        // Nullable SQL columns are produced only by this exhaustive enum mapping. The schema
        // independently requires exactly one complete scope and its permitted action.
        let studyID: UUID?
        let groupID: UUID?
        let participantID: UUID?
        let sourceBindingID: UUID?
        switch event.scope {
        case let .study(study, group):
            (studyID, groupID, participantID, sourceBindingID) = (study, group, nil, nil)
        case let .participantSource(participant, source):
            (studyID, groupID, participantID, sourceBindingID) = (nil, nil, participant, source)
        }
        try await sql.raw("""
            INSERT INTO audit_events (
                id, occurred_at, actor_issuer, actor_subject, initiator_issuer, initiator_subject,
                action, scope_kind, study_id, group_id, participant_id, source_binding_id,
                target_id, target_version, outcome, correlation_id, application_revision
            ) VALUES (
                \(bind: event.id), \(bind: event.occurredAt), \(bind: event.context.actor.issuer), \(bind: event.context.actor.subject),
                \(bind: event.context.initiator?.issuer), \(bind: event.context.initiator?.subject),
                \(bind: event.action.rawValue), \(bind: event.scope.kind.rawValue), \(bind: studyID), \(bind: groupID),
                \(bind: participantID), \(bind: sourceBindingID),
                \(bind: event.target.id), \(bind: event.target.version), \(bind: outcome),
                \(bind: event.context.correlationID), \(bind: event.context.applicationRevision)
            )
            """)
            .run()
        return AuditReceipt(id: event.id, occurredAt: event.occurredAt)
    }
}
