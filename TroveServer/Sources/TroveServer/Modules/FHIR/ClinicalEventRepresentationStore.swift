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


/// Additional exact custody bytes for one retained version, never additional facts or study grants.
/// Called inside the acceptance transaction with the participant/source owner already locked.
struct ClinicalEventRepresentationStore {
    private static var conflict: ServerError {
        .conflict("Record version conflicts with retained clinical content")
    }

    let database: any Database
    let source: SourceBinding
    let context: AuthContext

    /// Receipt recovery deliberately omits clinical bytes and does not re-evaluate authority.
    static func receipt(eventID: UUID, digest: String, on sql: any SQLDatabase) async throws -> ClinicalEventReceipt? {
        guard let row = try await sql.raw("""
            SELECT e.id, e.source_id, e.identifier_system, e.identifier_value, e.target_intent,
                r.raw_sha256, r.received_at, r.node_count
            FROM clinical_event_representations r JOIN clinical_events e ON e.id = r.event_id
            WHERE r.event_id = \(bind: eventID) AND r.raw_sha256 = \(bind: digest)
            """)
            .first() else { return nil }
        return try ClinicalEventReceipt(row: row)
    }

    func replay(_ event: ValidatedExchangeEvent, intent: ClinicalEventIntent, digest: String) async throws -> ClinicalEventReceipt? {
        guard let sql = database as? any SQLDatabase else { throw ServerError.unexpectedError }
        guard let original = try await sql.raw("""
            SELECT * FROM clinical_events WHERE identifier_system = \(bind: event.eventIdentifierSystem)
                AND identifier_value = \(bind: event.eventIdentifierValue)
            """)
            .first() else { return nil }
        guard try original.decode(column: "source_id", as: UUID.self) == source.id,
              try original.decode(column: "target_intent", as: String.self) == intent.serialized else {
            throw ServerError.conflict("Event identity already exists with different source or study targets")
        }
        if try original.decode(column: "raw_sha256", as: String.self) == digest {
            guard try original.decode(column: "raw_bytes", as: Data.self) == event.rawBytes else { throw Self.conflict }
            return try ClinicalEventReceipt(row: original)
        }
        let eventID = try original.decode(column: "id", as: UUID.self)
        if let retained = try await sql.raw("""
            SELECT raw_bytes FROM clinical_event_representations
            WHERE event_id = \(bind: eventID) AND raw_sha256 = \(bind: digest)
            """)
            .first() {
            guard try retained.decode(column: "raw_bytes", as: Data.self) == event.rawBytes else { throw Self.conflict }
        } else {
            let bytes = try original.decode(column: "raw_bytes", as: Data.self)
            try await verify(event.rawBytes, original: bytes, eventID: eventID, on: sql)
            try await insert(event, eventID: eventID, intent: intent, digest: digest, on: sql)
        }
        guard let receipt = try await Self.receipt(eventID: eventID, digest: digest, on: sql) else { throw ServerError.unexpectedError }
        return receipt
    }
}


extension ClinicalEventRepresentationStore {
    private func verify(_ bytes: Data, original: Data, eventID: UUID, on sql: any SQLDatabase) async throws {
        guard (try? ClinicalRecordEquivalence.accepts(bytes, asRepresentationOf: original)) == true else { throw Self.conflict }
        // A snapshot first seen in an additional representation is equally immutable.
        // Walk the composite key one bounded record at a time, without loading its whole history.
        var previousDigest = ""
        while let row = try await sql.raw("""
            SELECT raw_sha256, raw_bytes FROM clinical_event_representations
            WHERE event_id = \(bind: eventID) AND raw_sha256 > \(bind: previousDigest)
            ORDER BY raw_sha256 LIMIT 1
            """)
            .first() {
            let retained = try row.decode(column: "raw_bytes", as: Data.self)
            guard (try? ClinicalRecordEquivalence.accepts(bytes, asRepresentationOf: retained)) == true else { throw Self.conflict }
            previousDigest = try row.decode(column: "raw_sha256", as: String.self)
        }
    }

    private func insert(
        _ event: ValidatedExchangeEvent,
        eventID: UUID,
        intent: ClinicalEventIntent,
        digest: String,
        on sql: any SQLDatabase
    ) async throws {
        let receivedAt = Date()
        // A new representation is new custody, even though its clinical version is retained.
        // Producer enrollment snapshots confer no authority and cannot refresh existing grants.
        let grants = ClinicalGrantStore(database: database, source: source, context: context, acceptedAt: receivedAt)
        _ = try await grants.authorities(
            outputs: event.outputs.map { .init(fullURL: $0.fullURL, profile: $0.profile, effectiveAt: $0.effectiveAt) },
            intent: intent,
            requireCustodyCoverage: true
        )
        try await sql.raw("""
            INSERT INTO clinical_event_representations (event_id, raw_sha256, raw_bytes, validator_identity, received_at, node_count)
            VALUES (\(bind: eventID), \(bind: digest), \(bind: event.rawBytes), \(bind: event.validatorIdentity),
                \(bind: receivedAt), \(bind: event.nodes.count))
            """)
            .run()
        try await AuditRepository.recordMutation(.init(
            context: context.auditContext,
            action: .clinicalEventAccepted,
            scope: .participantSource(participantID: source.participantID, sourceBindingID: source.id),
            target: .init(id: eventID)
        ), on: database)
    }
}
