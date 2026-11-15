//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SQLKit


/// Exact temporal preselection avoids repeatedly scanning ineligible records or rounding source precision.
struct ProviderRetainedSelection {
    let connection: ProviderConnection
    let sourceToken: String
    let sql: any SQLDatabase

    func next(demand: ProviderDemand) async throws -> UUID? {
        let bounds = try temporalPredicate(demand)
        let current = ClinicalRecordStore.currentPredicate(on: sql)
        let row = try await sql.raw("""
            SELECT f.event_id FROM clinical_point_facts f
            JOIN clinical_record_events r ON r.event_id = f.event_id AND r.source_id = f.source_id
            WHERE f.source_id = \(bind: connection.sourceID) AND f.source_type_identifier = \(bind: sourceToken)
                AND f.profile = \(bind: demand.profile) AND \(bounds) AND \(current)
                AND NOT \(ClinicalRecordStore.retracted("f.record_id"))
                AND NOT EXISTS (SELECT 1 FROM study_data_grants granted
                    WHERE granted.node_id = f.node_id AND granted.consent_id = \(bind: demand.consentID))
                AND EXISTS (
                    SELECT 1 FROM provider_staged_records retained
                    JOIN provider_checkpoints checkpoint ON checkpoint.id = retained.checkpoint_id
                    JOIN provider_connections origin ON origin.id = checkpoint.connection_id
                    WHERE retained.event_id = f.event_id AND checkpoint.source_token = \(bind: sourceToken)
                        AND origin.participant_id = \(bind: connection.participantID)
                        AND origin.source_id = \(bind: connection.sourceID)
                        AND origin.account_pseudonym = \(bind: connection.accountPseudonym)
                )
            ORDER BY f.event_id LIMIT 1
            """)
            .first()
        return try row?.decode(column: "event_id", as: UUID.self)
    }

    func outputs(eventID: UUID) async throws -> [ClinicalGrantStore.Output] {
        let rows = try await sql.raw("""
            SELECT f.*, n.full_url FROM clinical_point_facts f JOIN clinical_event_nodes n ON n.id = f.node_id
            WHERE f.event_id = \(bind: eventID) AND f.source_id = \(bind: connection.sourceID)
            """)
            .all()
        return try rows.map {
            try .init(
                fullURL: $0.decode(column: "full_url", as: String.self),
                profile: $0.decode(column: "profile", as: String.self),
                measurementBounds: ClinicalMeasurementBounds(row: $0),
                codeSystem: $0.decode(column: "code_system", as: String.self),
                code: $0.decode(column: "code", as: String.self),
                sourceTypeIdentifier: $0.decode(column: "source_type_identifier", as: String?.self)
            )
        }
    }

    func temporalPredicate(_ demand: ProviderDemand) throws -> SQLQueryString {
        let lower = try RecordedInstant(authorityDate: demand.start)
        let upper = try RecordedInstant(authorityDate: demand.end)
        let asOf = try RecordedInstant(authorityDate: demand.asOf)
        let collation = sql.dialect.name == "sqlite" ? "BINARY" : "C"
        // Canonical fractions omit trailing zeroes; bytewise tuple ordering matches RecordedInstant.
        let start: SQLQueryString = "(f.effective_seconds, f.effective_fraction COLLATE \(ident: collation))"
        let end: SQLQueryString = "(f.effective_end_seconds, f.effective_end_fraction COLLATE \(ident: collation))"
        return """
            \(start) < (\(bind: upper.seconds), \(bind: upper.fraction))
            AND \(start) <= (\(bind: asOf.seconds), \(bind: asOf.fraction))
            AND (f.effective_end_seconds IS NULL OR \(end) <= (\(bind: asOf.seconds), \(bind: asOf.fraction)))
            AND ((f.effective_end_seconds IS NOT NULL AND \(end) > \(start)
                    AND \(end) > (\(bind: lower.seconds), \(bind: lower.fraction)))
                OR ((f.effective_end_seconds IS NULL OR \(end) = \(start))
                    AND \(start) >= (\(bind: lower.seconds), \(bind: lower.fraction))))
            """
    }
}
