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
import SQLKit


extension ProviderIngestionService {
    func prepare(connectionID: UUID, sourceToken: String, now: Date) async throws -> Dispatch? {
        if case .dispatch(let dispatch) = try await preparation(connectionID: connectionID, sourceToken: sourceToken, now: now) { return dispatch }
        return nil
    }

    func preparation(connectionID: UUID, sourceToken: String, now: Date) async throws -> Preparation {
        let initial = try await ProviderSQL.connection(connectionID, on: database)
        return try await database.transaction { transaction in
            try await ProviderSQL.lockParticipant(initial.participantID, on: transaction)
            let approved = try await ProviderRegistrationStore.requireApproved(initial.registrationID, on: transaction, lock: true)
            let connection = try await ProviderSQL.connection(connectionID, on: transaction)
            guard approved.configuration.provider == self.client.provider,
                  approved.configuration.sourceTokens.contains(sourceToken), connection.nextAttempt <= now else { return .deferred }
            let store = try await ProviderCheckpointStore(connectionID: connection.id, sourceToken: sourceToken, sql: ProviderSQL.sql(transaction))
            guard connection.status != .disconnected,
                  store.staged != nil || (connection.status == .active && connection.refreshState == .ready) else { return .deferred }
            let selection: (ProviderCheckpoint?, [ProviderDemand])
            if let staged = store.staged {
                let demands = try await ProviderDemandStore.load(
                    participantID: connection.participantID, registration: approved.configuration, sourceToken: sourceToken,
                    asOf: now, purpose: .retainedCustody, on: transaction
                )
                guard !demands.isEmpty else { return .noCurrentDemand }
                selection = (staged, demands)
            } else {
                selection = try await self.selectWindow(
                    store: store, connection: connection, registration: approved.configuration, now: now, on: transaction
                )
            }
            let (selected, demands) = selection
            guard let checkpoint = selected else { return demands.isEmpty ? .noCurrentDemand : .deferred }
            guard checkpoint.leaseUntil.map({ $0 <= now }) ?? true else { return .deferred }
            return try await .dispatch(self.dispatch(
                checkpoint: checkpoint, connection: connection, approved: approved, sourceToken: sourceToken,
                demands: demands, now: now, on: transaction
            ))
        }
    }

    // This transaction binds the exact connection, registration, source token and acquired page.
    // swiftlint:disable:next function_parameter_count
    private func dispatch(
        checkpoint: ProviderCheckpoint, connection: ProviderConnection, approved: ProviderRegistrationStore.Approved,
        sourceToken: String, demands: [ProviderDemand], now: Date, on transaction: any Database
    ) async throws -> Dispatch {
        let sql = try ProviderSQL.sql(transaction)
        guard checkpoint.generation < Int64.max else { throw ProviderFailure.capacityExceeded }
        let leaseID = UUID()
        let generation = checkpoint.generation + 1
        let acquiredAt = checkpoint.acquiredAt ?? now
        let retainedFacts = checkpoint.acquisitionFacts ?? self.facts
        try await sql.raw("""
            UPDATE provider_checkpoints SET generation = \(bind: generation), lease_id = \(bind: leaseID),
                lease_until = \(bind: now.addingTimeInterval(300)), acquired_at = \(bind: acquiredAt),
                acquisition_facts = \(bind: try ProviderSQL.encode(retainedFacts, maximumBytes: 16_384)),
                status = \(bind: checkpoint.status == .staged ? "staged" : "fetching") WHERE id = \(bind: checkpoint.id)
            """).run()
        let authority = ProviderWorkerAuthority(
            participantID: connection.participantID, connectionID: connection.id, registrationID: connection.registrationID,
            registrationGeneration: approved.generation, connectionGeneration: connection.generation,
            checkpointID: checkpoint.id, checkpointGeneration: generation, leaseID: leaseID,
            sourceToken: sourceToken, worker: self.worker
        )
        let authorized = try await authority.lock(on: transaction, now: now)
        let producer = try await producer(facts: retainedFacts, source: authorized.source, on: transaction)
        let scope = try await ProviderGlobalScopeStore.scope(
            provider: approved.configuration.provider, connection: connection, source: authorized.source, on: transaction
        )
        try await sql.raw("""
            UPDATE provider_connections SET last_attempt = \(bind: now), next_attempt = \(bind: now.addingTimeInterval(60)),
                dormant_until = \(bind: now.addingTimeInterval(self.dormantRetention)) WHERE id = \(bind: connection.id)
            """).run()
        try await AuditRepository.recordMutation(.init(
            context: authorized.audit, action: .providerFetchDispatched,
            scope: .participantProvider(participantID: connection.participantID, registrationID: connection.registrationID),
            target: .init(id: checkpoint.id, version: String(generation))
        ), on: transaction)
        return Dispatch(
            authority: authority,
            request: .init(
                registration: approved.configuration, sourceToken: sourceToken, window: checkpoint.window, cursor: checkpoint.cursor,
                acquiredAt: acquiredAt, queryAsOf: checkpoint.queryAsOf,
                conversionInstant: { nativeID, evidence in
                    guard evidence.count <= self.limits.recordBytes else { throw ProviderFailure.capacityExceeded }
                    return try await ProviderConversionInstantStore(database: self.database).instant(
                        nativeID: nativeID, evidence: evidence, authority: authority, producer: producer,
                        scope: scope, facts: retainedFacts, acquiredAt: acquiredAt
                    )
                },
                demands: authorized.demands, producer: producer, scope: scope
            ),
            pageSequence: checkpoint.pageSequence,
            staged: checkpoint.status == .staged
        )
    }

    private func producer(
        facts: ProviderAcquisitionFacts, source: SourceBinding, on transaction: any Database
    ) async throws -> ExchangeProducer {
        let identity = try await SourceIdentityKeyStore(keyring: keyring).recover(
            sourceID: source.id, participantID: source.participantID, on: transaction
        )
        return try facts.producer(source: source, identity: identity)
    }

    private func selectWindow(
        store: ProviderCheckpointStore, connection: ProviderConnection, registration: ProviderRegistration, now: Date, on transaction: any Database
    ) async throws -> (ProviderCheckpoint?, [ProviderDemand]) {
        var currentDemands: [ProviderDemand] = []
        for purpose in [ProviderCheckpoint.Purpose.reconciliation, .ordinary] {
            let demands = try await ProviderDemandStore.load(
                participantID: connection.participantID, registration: registration, sourceToken: store.sourceToken, asOf: now,
                purpose: purpose == .reconciliation ? .closedWindowReconciliation : .acquisition, on: transaction
            )
            currentDemands.append(contentsOf: demands)
            if let checkpoint = try await store.next(demands: demands, purpose: purpose, now: now) { return (checkpoint, demands) }
        }
        return (nil, currentDemands)
    }

}


enum ProviderWindowPlanner {
    /// Bound each backfill dispatch to one elapsed day without assuming a source's civil-day time zone.
    static func next(demands: [Range<Date>], completed: [Range<Date>]) -> Range<Date>? {
        let covered = completed.sorted { $0.lowerBound < $1.lowerBound }
        for demand in demands {
            var start = demand.lowerBound
            for interval in covered where interval.upperBound > start && interval.lowerBound < demand.upperBound {
                if interval.lowerBound > start {
                    return start..<min(interval.lowerBound, demand.upperBound, start.addingTimeInterval(86_400))
                }
                start = max(start, interval.upperBound)
            }
            if start < demand.upperBound { return start..<min(demand.upperBound, start.addingTimeInterval(86_400)) }
        }
        return nil
    }
}
