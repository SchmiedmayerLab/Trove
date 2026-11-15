//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Fluent
import Foundation
import GroveFHIRContract
import SQLKit
import TroveAPITypes


/// One bounded page per dispatch. Accepted records and the page checkpoint commit independently and recover exactly.
struct ProviderIngestionService: Sendable {
    enum Outcome: Sendable { case accepted, noCurrentDemand, deferred }
    enum Preparation: Sendable { case dispatch(Dispatch), noCurrentDemand, deferred }

    struct Dispatch: Sendable {
        let authority: ProviderWorkerAuthority
        let request: ProviderAcquisitionRequest
        let pageSequence: Int64
        let staged: Bool
    }

    let database: any Database
    let validator: FHIRValidationClient
    let credentialService: ProviderCredentialService
    let keyring: SourceIdentityKeyring
    let worker: ProviderWorkerIdentity
    let facts: ProviderAcquisitionFacts
    let limits: EventSubmissionLimits.Configuration
    let client: any ProviderAcquisitionClient
    var dormantRetention: TimeInterval = 86_400

    /// A configured provider implementation may process only the exact source tokens it qualifies.
    func run(connectionID: UUID, sourceToken: String, now: Date = Date()) async throws -> Bool {
        try await collect(connectionID: connectionID, sourceToken: sourceToken, now: now) == .accepted
    }

    func collect(connectionID: UUID, sourceToken: String, now: Date = Date()) async throws -> Outcome {
        guard client.qualifiedSourceTokens.contains(sourceToken) else { throw ProviderFailure.invalidConfiguration }
        let retained = ProviderRetainedAttribution(database: database, worker: worker, provider: client.provider)
        if try await retained.run(connectionID: connectionID, sourceToken: sourceToken, now: now) > 0 {
            return .accepted
        }
        let dispatch: Dispatch
        switch try await preparation(connectionID: connectionID, sourceToken: sourceToken, now: now) {
        case .dispatch(let prepared): dispatch = prepared
        case .noCurrentDemand: return .noCurrentDemand
        case .deferred: return .deferred
        }
        if !dispatch.staged {
            let credentials = try await credentialService.credentials(for: dispatch.authority, now: now)
            let page = try await client.fetch(dispatch.request, credentials: credentials)
            try Task.checkCancellation()
            try await stage(page, dispatch: dispatch)
        }
        try await drain(dispatch)
        return .accepted
    }

    private func stage(_ page: ProviderAcquisitionPage, dispatch: Dispatch) async throws {
        guard page.records.count <= 256, page.excludedRows >= 0, page.excludedRows <= 100_000,
              page.complete == (page.nextCursor == nil),
              page.nextCursor.map({ !$0.isEmpty && $0.utf8.count <= 4096 && $0 != dispatch.request.cursor }) ?? true else {
            throw ProviderFailure.invalidPayload
        }
        var total = 0
        for bytes in page.records {
            guard !bytes.isEmpty, bytes.count <= limits.recordBytes, bytes.count <= limits.bundleBytes - total else {
                throw ProviderFailure.capacityExceeded
            }
            total += bytes.count
        }
        // Complete validation precedes staging. The original page remains unacknowledged on any failure.
        for bytes in page.records {
            let identity = try await validator.validate(bytes)
            let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: identity)
            guard event.outputs.allSatisfy({ $0.sourceTypeIdentifier == dispatch.authority.sourceToken }) else {
                throw ProviderFailure.scopeLost
            }
        }
        try await database.transaction { transaction in
            let authorized = try await dispatch.authority.lock(on: transaction)
            let sql = try ProviderSQL.sql(transaction)
            for (ordinal, bytes) in page.records.enumerated() {
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                try await sql.raw("""
                    INSERT INTO provider_staged_records (
                        id, checkpoint_id, page_sequence, ordinal, record_bytes, record_digest, target_intent
                    ) VALUES (
                        \(bind: UUID()), \(bind: dispatch.authority.checkpointID), \(bind: dispatch.pageSequence),
                        \(bind: ordinal), \(bind: bytes), \(bind: digest), 'current-demand'
                    )
                    """).run()
            }
            try await sql.raw("""
                UPDATE provider_checkpoints SET status = 'staged', next_cursor = \(bind: page.nextCursor),
                    page_complete = \(bind: page.complete), excluded_rows = \(bind: page.excludedRows)
                WHERE id = \(bind: dispatch.authority.checkpointID)
                """).run()
            // An empty page is still an audited fetch outcome; it cannot synthesize clinical data.
            try await AuditRepository.recordMutation(.init(
                context: authorized.audit, action: .providerPageStaged,
                scope: .participantProvider(participantID: dispatch.authority.participantID, registrationID: dispatch.authority.registrationID),
                target: .init(id: dispatch.authority.checkpointID, version: String(dispatch.pageSequence))
            ), on: transaction)
        }
    }

    private func drain(_ dispatch: Dispatch) async throws {
        let sql = try ProviderSQL.sql(database)
        while let row = try await sql.raw("""
            SELECT id, record_bytes, record_digest FROM provider_staged_records
            WHERE checkpoint_id = \(bind: dispatch.authority.checkpointID) AND page_sequence = \(bind: dispatch.pageSequence)
                AND event_id IS NULL ORDER BY ordinal LIMIT 1
            """).first() {
            try Task.checkCancellation()
            let id = try row.decode(column: "id", as: UUID.self)
            let bytes = try row.decode(column: "record_bytes", as: Data.self)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard try row.decode(column: "record_digest", as: String.self) == digest else { throw ProviderFailure.unavailable }
            let validatorIdentity = try await validator.validate(bytes)
            let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: validatorIdentity)
            try await database.transaction { transaction in
                let receipt = try await ClinicalEventStore(database: transaction).accept(
                    event, commandID: id, worker: dispatch.authority, on: transaction
                )
                try await ProviderSQL.sql(transaction).raw("""
                    UPDATE provider_staged_records SET event_id = \(bind: receipt.eventID) WHERE id = \(bind: id) AND event_id IS NULL
                    """).run()
            }
        }
        let exhausted = try await complete(dispatch)
        if exhausted { throw ProviderFailure.capacityExceeded }
    }

    private func complete(_ dispatch: Dispatch) async throws -> Bool {
        try await database.transaction { transaction in
            let authorized = try await dispatch.authority.lock(on: transaction)
            let sql = try ProviderSQL.sql(transaction)
            guard let row = try await sql.raw("""
                SELECT page_complete, next_cursor FROM provider_checkpoints WHERE id = \(bind: dispatch.authority.checkpointID) AND status = 'staged'
                """).first(),
                  try await sql.raw("""
                    SELECT id FROM provider_staged_records WHERE checkpoint_id = \(bind: dispatch.authority.checkpointID)
                        AND page_sequence = \(bind: dispatch.pageSequence) AND event_id IS NULL LIMIT 1
                    """).first() == nil else { throw ProviderFailure.fenced }
            let complete = try row.decode(column: "page_complete", as: Bool.self)
            guard dispatch.pageSequence < Int64.max else { throw ProviderFailure.capacityExceeded }
            let exhausted = !complete && dispatch.pageSequence >= ProviderCheckpoint.maximumPages
            let status = complete ? "complete" : (exhausted ? "blocked" : "ready")
            try await sql.raw("""
                UPDATE provider_checkpoints SET status = \(bind: status),
                    cursor = \(bind: row.decode(column: "next_cursor", as: String?.self)), next_cursor = NULL,
                    accepted_through = \(bind: complete ? dispatch.request.window.upperBound : nil),
                    lease_id = NULL, lease_until = NULL, acquired_at = NULL, acquisition_facts = NULL,
                    page_sequence = page_sequence + 1 WHERE id = \(bind: dispatch.authority.checkpointID)
                """).run()
            try await sql.raw("""
                UPDATE provider_connections SET last_successful_fetch = \(bind: Date()), next_attempt = \(bind: Date().addingTimeInterval(60))
                WHERE id = \(bind: dispatch.authority.connectionID)
                """).run()
            try await AuditRepository.recordMutation(.init(
                context: authorized.audit, action: .providerPageAccepted,
                scope: .participantProvider(participantID: dispatch.authority.participantID, registrationID: dispatch.authority.registrationID),
                target: .init(id: dispatch.authority.checkpointID, version: String(dispatch.pageSequence))
            ), on: transaction)
            return exhausted
        }
    }
}
