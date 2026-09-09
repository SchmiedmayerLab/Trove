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
import SQLKit


/// Immutable point-event history and exact study grants. Revision selection never grants authority.
struct ClinicalEventStore: Sendable {
    private struct Acceptance: Sendable {
        let receipt: ClinicalEventReceipt
        let source: SourceBinding
        let intent: String
        let digest: String
        let context: AuthContext
    }

    let database: any Database

    /// Repository-level diagnostic for isolated tests; not a participant or researcher API.
    /// Future exports must authorize their caller and project independently allowed fields;
    /// this availability count does not authorize disclosure of an entire supporting response or Bundle.
    func effectiveGrantCount(studyID: UUID, currentOnly: Bool = true) async throws -> Int {
        let sql = try sql(on: database)
        let selection: SQLQueryString = currentOnly ? ClinicalRecordStore.currentPredicate(on: sql) : "1 = 1"
        let row = try await sql.raw("""
            SELECT COUNT(DISTINCT g.node_id) AS count FROM study_data_grants g
            JOIN enrollments e ON e.id = g.enrollment_id AND e.study_id = g.study_id
            JOIN enrollment_consents c ON c.id = g.consent_id AND c.enrollment_id = e.id AND c.revision = g.revision
            JOIN published_studies p ON p.id = g.publication_id AND p.study_id = g.study_id AND p.revision = g.revision
            JOIN clinical_event_nodes n ON n.id = g.node_id
            JOIN clinical_point_facts f ON f.node_id = n.id
            JOIN clinical_record_events r ON r.event_id = n.event_id
            JOIN source_bindings s ON s.id = n.source_id AND s.participant_id = e.participant_id
            WHERE g.study_id = \(bind: studyID) AND e.withdrawn_at IS NULL
                AND NOT EXISTS (SELECT 1 FROM clinical_output_retractions t WHERE t.output_binding_id = f.output_binding_id)
                AND \(selection)
                AND \(ClinicalGraphStore.disclosurePredicate)
            """)
            .first()
        guard let row else { throw ServerError.unexpectedError }
        return try row.decode(column: "count", as: Int.self)
    }

    func accept(_ event: ValidatedExchangeEvent, sourceID: UUID, targets: [ClinicalEventTarget]) async throws -> ClinicalEventReceipt {
        let context = try AuthContext.checkIsParticipant()
        try validateBounds(event)
        try ClinicalGraphStore.validate(event)
        let revision = try ClinicalRecordRevision(event)
        let intent = try ClinicalEventIntent(targets: targets)
        guard event.retraction == nil ? !targets.isEmpty : targets.isEmpty else {
            throw ServerError.badRequest("Active events require study targets; retractions must not grant study access")
        }
        let digest = SHA256.hash(data: event.rawBytes).map { String(format: "%02x", $0) }.joined()
        do {
            return try await database.transaction { transaction in
                let source = try await self.lockSourceOwner(sourceID: sourceID, context: context, on: transaction)
                try self.validateSource(event, source: source)
                if let receipt = try await self.replay(event, sourceID: sourceID, intent: intent.serialized, digest: digest, on: transaction) {
                    return receipt
                }
                let receivedAt = Date()
                let grants = ClinicalGrantStore(database: transaction, source: source, context: context, acceptedAt: receivedAt)
                let authorities = try await grants.authorities(
                    outputs: event.outputs.map { .init(fullURL: $0.fullURL, profile: $0.profile, effectiveAt: $0.effectiveAt) },
                    intent: intent,
                    requireCustodyCoverage: true
                )
                let receipt = ClinicalEventReceipt(
                    eventID: UUID(),
                    sourceID: sourceID,
                    producerEventIdentifier: .init(system: event.eventIdentifierSystem, value: event.eventIdentifierValue),
                    payloadSHA256: digest,
                    targetIntentSHA256: intent.sha256,
                    receivedAt: receivedAt,
                    nodeCount: event.nodes.count
                )
                let acceptance = Acceptance(receipt: receipt, source: source, intent: intent.serialized, digest: digest, context: context)
                try await self.insert(event, revision: revision, acceptance: acceptance, authorities: authorities, on: transaction)
                // Return the persisted timestamp precision on the first response as well as replay.
                let persisted = try await self.replay(event, sourceID: sourceID, intent: intent.serialized, digest: digest, on: transaction)
                guard let persisted else {
                    throw ServerError.unexpectedError
                }
                return persisted
            }
        } catch where (error as? any DatabaseError)?.isConstraintFailure == true {
            throw ServerError.conflict("Clinical event identity or scoped output binding conflicts with retained history")
        }
    }

    private func validateBounds(_ event: ValidatedExchangeEvent) throws {
        guard (1...512).contains(event.nodes.count),
              event.retraction == nil || (event.nodes.count == 1 && event.nodes[0].resourceType == "Provenance" && event.participants.isEmpty),
              event.outputs.count <= event.nodes.count,
              !event.rawBytes.isEmpty, event.rawBytes.count <= FHIRValidationClient.maximumBytes, !event.validatorIdentity.isEmpty,
              Set(event.nodes.map(\.fullURL)).count == event.nodes.count,
              Set(event.nodes.map(\.ordinal)) == Set(0..<event.nodes.count),
              Set(event.outputs.map(\.fullURL)).count == event.outputs.count,
              event.outputs.allSatisfy({ output in
                  event.nodes.contains { $0.fullURL == output.fullURL && $0.resourceType == "Observation" }
              }) else {
            throw ServerError.badRequest("Unsupported or unbounded immutable point event")
        }
    }

    func lockSourceOwner(
        sourceID: UUID, context: AuthContext, on transaction: any Database, requireActive: Bool = true
    ) async throws -> SourceBinding {
        let sql = try sql(on: transaction)
        // Registration/revocation use the same participant lock. Consent uses participant→enrollment.
        let owner = try await sql.raw("""
            UPDATE participants SET id = id
            WHERE identity_provider_issuer = \(bind: context.issuer) AND identity_provider_id = \(bind: context.subject)
            RETURNING id
            """)
            .first()
        guard let owner else { throw ServerError.notFound("Source binding not found") }
        let participantID = try owner.decode(column: "id", as: UUID.self)
        let row = try await sql.raw("SELECT * FROM source_bindings WHERE id = \(bind: sourceID) AND participant_id = \(bind: participantID)").first()
        guard let row else { throw ServerError.notFound("Source binding not found") }
        let source = try SourceBinding(row: row)
        guard !requireActive || (source.revokedAt == nil && source.kind == .participantApp) else {
            throw ServerError.conflict("Source binding is not active")
        }
        return source
    }

    private func validateSource(_ event: ValidatedExchangeEvent, source: SourceBinding) throws {
        let participant = ValidatedExchangeEvent.Identifier(system: source.participantIdentifierSystem, value: source.participantIdentifierValue)
        guard event.producerInstance == source.producerInstance, event.eventIdentifierSystem == source.eventIdentifierSystem,
              event.retraction == nil ? event.participants == [participant] : event.participants.isEmpty,
              event.eventIdentifierValue.hasPrefix("e0:\(source.id.uuidString.lowercased()):") else {
            throw ServerError.forbidden("Event identity does not match the registered participant source")
        }
    }

    private func replay(
        _ event: ValidatedExchangeEvent, sourceID: UUID, intent: String, digest: String, on transaction: any Database
    ) async throws -> ClinicalEventReceipt? {
        let row = try await sql(on: transaction).raw("""
            SELECT * FROM clinical_events WHERE identifier_system = \(bind: event.eventIdentifierSystem)
                AND identifier_value = \(bind: event.eventIdentifierValue)
            """)
            .first()
        guard let row else {
            return nil
        }
        guard try row.decode(column: "source_id", as: UUID.self) == sourceID,
              try row.decode(column: "target_intent", as: String.self) == intent,
              try row.decode(column: "raw_sha256", as: String.self) == digest,
              try row.decode(column: "raw_bytes", as: Data.self) == event.rawBytes else {
            throw ServerError.conflict("Event identity already exists with different bytes or study targets")
        }
        return try ClinicalEventReceipt(row: row)
    }

    private func insert(
        _ event: ValidatedExchangeEvent,
        revision: ClinicalRecordRevision,
        acceptance: Acceptance,
        authorities: [ClinicalGrantStore.Authority],
        on transaction: any Database
    ) async throws {
        let sql = try sql(on: transaction)
        let receipt = acceptance.receipt
        try await sql.raw("""
            INSERT INTO clinical_events (id, source_id, identifier_system, identifier_value, raw_bytes, raw_sha256,
                validator_identity, target_intent, received_at, node_count)
            VALUES (\(bind: receipt.eventID), \(bind: receipt.sourceID), \(bind: event.eventIdentifierSystem),
                \(bind: event.eventIdentifierValue), \(bind: event.rawBytes), \(bind: acceptance.digest), \(bind: event.validatorIdentity),
                \(bind: acceptance.intent), \(bind: receipt.receivedAt), \(bind: receipt.nodeCount))
            """)
            .run()
        let records = ClinicalRecordStore(sql: sql)
        let grants = ClinicalGrantStore(database: transaction, source: acceptance.source, context: acceptance.context, acceptedAt: receipt.receivedAt)
        let recordID = try await records.insert(revision, eventID: receipt.eventID, sourceID: receipt.sourceID)
        for output in event.retraction?.outputIdentifiers ?? [] {
            try await records.retract(output, recordID: recordID, sourceID: receipt.sourceID, eventID: receipt.eventID)
        }
        let nodeIDs = Dictionary(uniqueKeysWithValues: event.nodes.map { ($0.fullURL, UUID()) })
        for node in event.nodes {
            guard let nodeID = nodeIDs[node.fullURL] else { throw ServerError.unexpectedError }
            try await sql.raw("""
                INSERT INTO clinical_event_nodes (id, event_id, source_id, full_url, ordinal, resource_type)
                VALUES (\(bind: nodeID), \(bind: receipt.eventID), \(bind: receipt.sourceID),
                    \(bind: node.fullURL), \(bind: node.ordinal), \(bind: node.resourceType))
                """)
                .run()
            if let output = event.outputs.first(where: { $0.fullURL == node.fullURL }) {
                let bindingID = try await records.bind(
                    output.sourceOutputIdentifier, recordID: recordID, sourceID: receipt.sourceID, eventID: receipt.eventID
                )
                try await records.insertPoint(output, nodeID: nodeID, recordID: recordID, bindingID: bindingID, receipt: receipt)
                for authority in authorities where authority.outputs.contains(node.fullURL) {
                    _ = try await grants.insert(authority, nodeID: nodeID)
                }
            }
        }
        try await ClinicalGraphStore(sql: sql).insert(event, nodeIDs: nodeIDs, receipt: receipt)
        try await AuditRepository.recordMutation(.init(
            context: acceptance.context.auditContext,
            action: .clinicalEventAccepted,
            scope: .participantSource(participantID: acceptance.source.participantID, sourceBindingID: receipt.sourceID),
            target: .init(id: receipt.eventID)
        ), on: transaction)
    }

    private func sql(on database: any Database) throws -> any SQLDatabase {
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        return sql
    }
}
