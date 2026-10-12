//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import SQLKit


/// One complete source-record revision, not a per-output or arrival-order winner.
struct ClinicalRecordRevision: Sendable {
    let identifier: ValidatedExchangeEvent.Identifier
    let writer: ValidatedExchangeEvent.Identifier?
    let version: String?
    let kind: String

    init(_ event: ValidatedExchangeEvent) throws {
        if let retraction = event.retraction {
            guard event.outputs.isEmpty, Self.bounded(retraction.sourceRecordIdentifier),
                  (1...512).contains(retraction.outputIdentifiers.count),
                  Set(retraction.outputIdentifiers).count == retraction.outputIdentifiers.count,
                  retraction.outputIdentifiers.allSatisfy(Self.bounded) else {
                throw ServerError.badRequest("Unsupported retraction targets")
            }
            identifier = retraction.sourceRecordIdentifier
            writer = nil
            version = nil
            kind = "retraction"
            return
        }
        guard let first = event.outputs.first,
              Self.bounded(first.sourceRecordIdentifier),
              Set(event.outputs.map(\.sourceOutputIdentifier)).count == event.outputs.count,
              event.outputs.allSatisfy({
                  $0.sourceRecordIdentifier == first.sourceRecordIdentifier
                      && $0.writerIdentifier == first.writerIdentifier && $0.writerVersion == first.writerVersion
                      && Self.bounded($0.sourceOutputIdentifier)
              }) else { throw ServerError.badRequest("A complete event requires one consistent bounded source-record revision") }
        switch (first.writerIdentifier, first.writerVersion) {
        case (nil, nil): break
        case let (.some(writer), .some(version)):
            guard Self.bounded(writer), version.utf8.count <= 4096,
                  Self.isCanonicalWriterVersion(version) else {
                throw ServerError.badRequest("Unsupported writer revision evidence")
            }
        default: throw ServerError.badRequest("Incomplete writer revision evidence")
        }
        identifier = first.sourceRecordIdentifier
        writer = first.writerIdentifier
        version = first.writerVersion
        kind = "active"
    }

    private static func isCanonicalWriterVersion(_ value: String) -> Bool {
        guard let first = value.utf8.first else {
            return false
        }
        if first == 48 {
            return value == "0"
        }
        return (49...57).contains(first) && value.utf8.dropFirst().allSatisfy { (48...57).contains($0) }
    }

    private static func bounded(_ identifier: ValidatedExchangeEvent.Identifier) -> Bool {
        (1...512).contains(identifier.system.utf8.count) && (1...512).contains(identifier.value.utf8.count)
    }
}


/// Called only inside the event acceptance transaction after locking the participant/source owner.
struct ClinicalRecordStore: Sendable {
    let sql: any SQLDatabase

    func insertPoint(
        _ output: ValidatedExchangeEvent.PointOutput,
        nodeID: UUID,
        recordID: UUID,
        bindingID: UUID,
        receipt: ClinicalEventReceipt
    ) async throws {
        try await sql.raw("""
            INSERT INTO clinical_point_facts (node_id, source_id, event_id, record_id, output_binding_id, profile, effective_at,
                quantity_value, quantity_system, quantity_code, code_system, code)
            VALUES (\(bind: nodeID), \(bind: receipt.sourceID), \(bind: receipt.eventID), \(bind: recordID), \(bind: bindingID),
                \(bind: output.profile), \(bind: output.effectiveAt),
                \(bind: output.quantityValue), \(bind: output.quantitySystem), \(bind: output.quantityCode), \(bind: output.codeSystem), \(bind: output.code))
            """)
            .run()
    }

    func insert(_ revision: ClinicalRecordRevision, eventID: UUID, sourceID: UUID) async throws -> UUID {
        let existing = try await sql.raw("""
            SELECT id FROM clinical_source_records WHERE source_id = \(bind: sourceID)
                AND identifier_system = \(bind: revision.identifier.system) AND identifier_value = \(bind: revision.identifier.value)
            """)
            .first()
        let recordID: UUID
        if let existing {
            recordID = try existing.decode(column: "id", as: UUID.self)
        } else {
            recordID = UUID()
            try await sql.raw("""
                INSERT INTO clinical_source_records (id, source_id, identifier_system, identifier_value)
                VALUES (\(bind: recordID), \(bind: sourceID), \(bind: revision.identifier.system), \(bind: revision.identifier.value))
                """)
                .run()
        }
        try await sql.raw("""
            INSERT INTO clinical_record_events (event_id, source_id, record_id, kind, writer_system, writer_value, writer_version)
            VALUES (\(bind: eventID), \(bind: sourceID), \(bind: recordID), \(bind: revision.kind),
                \(bind: revision.writer?.system), \(bind: revision.writer?.value), \(bind: revision.version))
            """)
            .run()
        return recordID
    }

    func bind(_ output: ValidatedExchangeEvent.Identifier, recordID: UUID, sourceID: UUID, eventID: UUID) async throws -> UUID {
        let existing = try await sql.raw("""
            SELECT id, record_id FROM clinical_output_bindings WHERE source_id = \(bind: sourceID)
                AND identifier_system = \(bind: output.system) AND identifier_value = \(bind: output.value)
            """)
            .first()
        if let existing {
            guard try existing.decode(column: "record_id", as: UUID.self) == recordID else {
                throw ServerError.conflict("Source output is already bound to a different source record")
            }
            return try existing.decode(column: "id", as: UUID.self)
        }
        let bindingID = UUID()
        try await sql.raw("""
            INSERT INTO clinical_output_bindings (id, source_id, record_id, first_event_id, identifier_system, identifier_value)
            VALUES (\(bind: bindingID), \(bind: sourceID), \(bind: recordID), \(bind: eventID),
                \(bind: output.system), \(bind: output.value))
            """)
            .run()
        return bindingID
    }

    func retract(_ output: ValidatedExchangeEvent.Identifier, recordID: UUID, sourceID: UUID, eventID: UUID) async throws {
        let bindingID = try await bind(output, recordID: recordID, sourceID: sourceID, eventID: eventID)
        try await sql.raw("""
            INSERT INTO clinical_output_retractions (event_id, source_id, record_id, output_binding_id, kind)
            VALUES (\(bind: eventID), \(bind: sourceID), \(bind: recordID), \(bind: bindingID), 'retraction')
            """)
            .run()
    }
}


extension ClinicalRecordStore {
    /// Predicate for an active record-event aliased `r`. Selection conveys no read authority.
    /// A missing/different writer or an equal/higher competing version prevents selection.
    /// Equal older versions do not prevent a uniquely higher complete revision from being selected.
    static func currentPredicate(on sql: any SQLDatabase) -> SQLQueryString {
        let collation = sql.dialect.name == "sqlite" ? "BINARY" : "C"
        return """
            r.kind = 'active' AND NOT EXISTS (
                SELECT 1 FROM clinical_record_events other
                WHERE other.record_id = r.record_id AND other.kind = 'active' AND other.event_id <> r.event_id
                    AND (r.writer_version IS NULL OR other.writer_version IS NULL
                        OR r.writer_system <> other.writer_system OR r.writer_value <> other.writer_value
                        OR length(other.writer_version) > length(r.writer_version)
                        OR (length(other.writer_version) = length(r.writer_version)
                            AND other.writer_version COLLATE \(ident: collation) >= r.writer_version COLLATE \(ident: collation)))
            )
            """
    }
}
