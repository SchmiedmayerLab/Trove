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


/// A retraction is a tombstone over retained custody: no event, fact or grant is removed when it is accepted.
/// Reversing it appends evidence that the tombstone no longer applies; nothing is rewritten.
extension ClinicalRecordStore {
    /// Whether the source record `record` (a SQL expression for its id) is suppressed by a tombstone that still applies.
    static func retracted(_ record: SQLQueryString) -> SQLQueryString {
        """
        EXISTS (SELECT 1 FROM clinical_record_retractions tombstone WHERE tombstone.record_id = \(record)
            AND NOT EXISTS (SELECT 1 FROM clinical_retraction_reversals reversal WHERE reversal.retraction_event_id = tombstone.event_id))
        """
    }
}


extension ClinicalEventStore {
    /// Operator custody action, not reachable through HTTP. Returns whether this call reversed the tombstone;
    /// repeating it changes nothing. The retraction of a source record has one identity, so a later repeat of
    /// the same deletion report replays its retained receipt and does not suppress the record again.
    @discardableResult
    func reverseRetraction(eventID: UUID, auditContext: AuditEvent.Context, at instant: Date = Date()) async throws -> Bool {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
            guard let row = try await sql.raw("""
                SELECT t.source_id, s.participant_id,
                    (SELECT COUNT(*) FROM clinical_retraction_reversals v WHERE v.retraction_event_id = t.event_id) AS reversals
                FROM clinical_record_retractions t JOIN source_bindings s ON s.id = t.source_id WHERE t.event_id = \(bind: eventID)
                """)
                .first() else { throw ServerError.notFound("Retraction not found") }
            guard try row.decode(column: "reversals", as: Int.self) == 0 else {
                return false
            }
            try await sql.raw("""
                INSERT INTO clinical_retraction_reversals (retraction_event_id, reversed_at) VALUES (\(bind: eventID), \(bind: instant))
                """)
                .run()
            try await AuditRepository.recordMutation(.init(
                context: auditContext,
                action: .clinicalRetractionReversed,
                scope: .participantSource(
                    participantID: try row.decode(column: "participant_id", as: UUID.self),
                    sourceBindingID: try row.decode(column: "source_id", as: UUID.self)
                ),
                target: .init(id: eventID)
            ), on: transaction)
            return true
        }
    }
}
