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


/// Reuses accepted custody for a new consent without fetching or rewriting the source record.
struct ProviderRetainedAttribution: Sendable {
    static let maximumRecordsPerPass = 32

    let database: any Database
    let worker: ProviderWorkerIdentity
    let provider: ConnectedProvider

    func run(connectionID: UUID, sourceToken: String, now: Date) async throws -> Int {
        let initial = try await ProviderSQL.connection(connectionID, on: database)
        return try await database.transaction { transaction in
            try await self.runLocked(initial: initial, sourceToken: sourceToken, now: now, on: transaction)
        }
    }

    private func runLocked(
        initial: ProviderConnection, sourceToken: String, now: Date, on transaction: any Database
    ) async throws -> Int {
        try await ProviderSQL.lockParticipant(initial.participantID, on: transaction)
        let approved = try await ProviderRegistrationStore.requireApproved(initial.registrationID, on: transaction, lock: true)
        let connection = try await ProviderSQL.connection(initial.id, on: transaction)
        guard connection.status != .disconnected, approved.configuration.provider == self.provider,
              approved.configuration.sourceTokens.contains(sourceToken) else { throw ProviderFailure.fenced }
        let sql = try ProviderSQL.sql(transaction)
        guard let row = try await sql.raw("SELECT * FROM source_bindings WHERE id = \(bind: connection.sourceID)").first() else {
            throw ProviderFailure.fenced
        }
        let source = try SourceBinding(row: row)
        guard source.participantID == connection.participantID, source.kind == .serverWorker,
              source.repositoryKind == self.provider.repositoryKind, source.revokedAt == nil else { throw ProviderFailure.fenced }
        let demands = try await ProviderDemandStore.load(
            participantID: connection.participantID,
            registration: approved.configuration,
            sourceToken: sourceToken,
            asOf: now,
            purpose: .retainedCustody,
            on: transaction
        )
        guard !demands.isEmpty else {
            return 0
        }
        let authorized = try await ProviderWorkerAuthority.Authorized(
            registrationID: connection.registrationID,
            source: source,
            audit: self.worker.audit(participantID: connection.participantID, on: transaction),
            demands: demands
        )
        let selection = ProviderRetainedSelection(connection: connection, sourceToken: sourceToken, sql: sql)
        var attributed = 0
        for demand in demands {
            while attributed < Self.maximumRecordsPerPass, let eventID = try await selection.next(demand: demand) {
                let outputs = try await selection.outputs(eventID: eventID)
                let selected = try FHIRWorkoutProjection.collectionOutputs(outputs).filter { try demand.contains($0) }
                guard !selected.isEmpty else { throw ProviderFailure.unavailable }
                _ = try await ClinicalAttributionStore(database: transaction).attribute(
                    eventID: eventID,
                    commandID: UUID(),
                    targets: [.init(consentID: demand.consentID, outputFullURLs: selected.map(\.fullURL).sorted())],
                    authorization: authorized,
                    sourceToken: sourceToken
                )
                attributed += 1
            }
            if attributed == Self.maximumRecordsPerPass { break }
        }
        return attributed
    }
}
