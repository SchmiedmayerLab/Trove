//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SQLKit


struct StudyAuditPage: Sendable {
    let studyID: UUID
    let records: [StudyAuditRecord]
    let nextBefore: UUID?
}


struct StudyAuditRecord: Sendable {
    enum Outcome: String, Codable, Sendable {
        case succeeded
        case disclosureIntent = "disclosure_intent"
    }

    let id: UUID
    let occurredAt: Date
    let actor: AuditActor
    let initiator: AuditActor?
    let executingClientID: String?
    let delegationID: UUID?
    let action: AuditEvent.Action
    let target: AuditEvent.Target
    let outcome: Outcome
    let correlationID: UUID
    let applicationRevision: String?

    init(row: any SQLRow) throws {
        id = try row.decode(column: "id", as: UUID.self)
        occurredAt = try row.decode(column: "occurred_at", as: Date.self)
        actor = try .init(
            issuer: row.decode(column: "actor_issuer", as: String.self),
            subject: row.decode(column: "actor_subject", as: String.self)
        )
        switch try (row.decode(column: "initiator_issuer", as: String?.self), row.decode(column: "initiator_subject", as: String?.self)) {
        case let (issuer?, subject?): initiator = .init(issuer: issuer, subject: subject)
        case (nil, nil): initiator = nil
        default: throw AuditError.invalidMetadata
        }
        executingClientID = try row.decode(column: "executing_client_id", as: String?.self)
        delegationID = try row.decode(column: "delegation_id", as: UUID?.self)
        action = try row.decode(column: "action", as: AuditEvent.Action.self)
        outcome = try row.decode(column: "outcome", as: Outcome.self)
        guard action.scopeKind == .study,
              action.isDisclosure == (outcome == .disclosureIntent) else {
            throw AuditError.invalidScope
        }
        target = try .init(
            id: row.decode(column: "target_id", as: UUID.self),
            version: row.decode(column: "target_version", as: String?.self)
        )
        correlationID = try row.decode(column: "correlation_id", as: UUID.self)
        applicationRevision = try row.decode(column: "application_revision", as: String?.self)
    }
}
