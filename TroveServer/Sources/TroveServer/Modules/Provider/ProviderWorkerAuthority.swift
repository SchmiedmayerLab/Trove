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


/// Deployment-configured worker identity. Participant claims never construct this value.
struct ProviderWorkerIdentity: Sendable {
    let issuer: String
    let clientID: String
    let applicationRevision: String?

    func audit(participantID: UUID, on database: any Database) async throws -> AuditEvent.Context {
        guard !issuer.isEmpty, issuer.utf8.count <= 2048, !clientID.isEmpty, clientID.utf8.count <= 255,
              let row = try await ProviderSQL.sql(database)
                .raw("""
                SELECT identity_provider_issuer, identity_provider_id FROM participants WHERE id = \(bind: participantID)
                """)
                .first() else { throw ProviderFailure.invalidConfiguration }
        return try .init(
            actor: .init(issuer: issuer, subject: clientID),
            initiator: .init(
                issuer: row.decode(column: "identity_provider_issuer", as: String.self),
                subject: row.decode(column: "identity_provider_id", as: String.self)
            ),
            executingClientID: clientID,
            applicationRevision: applicationRevision
        )
    }
}


/// A server-held dispatch fence, not a bearer capability returned through HTTP.
struct ProviderWorkerAuthority: Sendable {
    struct Authorized: Sendable {
        let registrationID: UUID
        let source: SourceBinding
        let audit: AuditEvent.Context
        let demands: [ProviderDemand]
    }

    let participantID: UUID
    let connectionID: UUID
    let registrationID: UUID
    let registrationGeneration: Int64
    let connectionGeneration: Int64
    let checkpointID: UUID
    let checkpointGeneration: Int64
    let leaseID: UUID
    let sourceToken: String
    let worker: ProviderWorkerIdentity

    func lock(on database: any Database, now: Date = Date()) async throws -> Authorized {
        try await ProviderSQL.lockParticipant(participantID, on: database)
        let approved = try await ProviderRegistrationStore.requireApproved(registrationID, on: database, lock: true)
        let connection = try await ProviderSQL.connection(connectionID, on: database)
        guard approved.generation == registrationGeneration,
              approved.configuration.sourceTokens.contains(sourceToken),
              connection.participantID == participantID, connection.registrationID == registrationID,
              connection.generation == connectionGeneration, connection.status != .disconnected else { throw ProviderFailure.fenced }
        let sql = try ProviderSQL.sql(database)
        guard let checkpoint = try await sql.raw("""
            SELECT * FROM provider_checkpoints WHERE id = \(bind: checkpointID) AND connection_id = \(bind: connectionID)
                AND source_token = \(bind: sourceToken) AND generation = \(bind: checkpointGeneration)
                AND lease_id = \(bind: leaseID) AND lease_until > \(bind: now) AND status IN ('fetching', 'staged')
            """)
            .first(),
              try checkpoint.decode(column: "id", as: UUID.self) == checkpointID,
              let row = try await sql.raw("SELECT * FROM source_bindings WHERE id = \(bind: connection.sourceID)").first() else {
            throw ProviderFailure.fenced
        }
        let retained = try checkpoint.decode(column: "status", as: String.self) == "staged"
        guard retained || connection.status == .active else { throw ProviderFailure.fenced }
        let source = try SourceBinding(row: row)
        guard source.participantID == participantID,
              source.kind == .serverWorker, source.revokedAt == nil,
              source.repositoryKind == approved.configuration.provider.repositoryKind else { throw ProviderFailure.fenced }
        let reconciliation = try checkpoint.decode(column: "purpose", as: String.self) == ProviderCheckpoint.Purpose.reconciliation.rawValue
        let queryAsOf = try checkpoint.decode(column: "query_as_of", as: Date.self)
        let currentDemands = try await ProviderDemandStore.load(
            participantID: participantID,
            registration: approved.configuration,
            sourceToken: sourceToken,
            asOf: now,
            purpose: retained ? .retainedCustody : (reconciliation ? .closedWindowReconciliation : .acquisition),
            on: database
        )
        .map { demand in
            var bounded = demand
            bounded.asOf = min(demand.asOf, queryAsOf)
            return bounded
        }
        let retainedCheckpoint = try ProviderCheckpoint(row: checkpoint)
        let demands = try retainedCheckpoint.coverage.intersecting(currentDemands)
        guard !demands.isEmpty else { throw ProviderFailure.scopeLost }
        return try await Authorized(
            registrationID: registrationID, source: source, audit: worker.audit(participantID: participantID, on: database), demands: demands
        )
    }
}
