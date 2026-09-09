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


/// Receipt recovery does not admit data or re-evaluate study grants.
struct ClinicalEventReceiptStore: Sendable {
    struct Lookup: Sendable {
        let identifier: ExchangeEventIdentifier
        let digest: String
        let intent: String

        init(system: String, value: String, digest: String, targets: [ClinicalEventTarget]) throws {
            guard (1...4096).contains(system.utf8.count), (1...4096).contains(value.utf8.count),
                  digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw ServerError.badRequest("Invalid receipt lookup")
            }
            do {
                identifier = try ExchangeEventIdentifier(BusinessIdentifier(system: system, value: value, role: .event))
            } catch {
                throw ServerError.badRequest("Invalid receipt lookup")
            }
            self.digest = digest
            intent = try ClinicalEventIntent(targets: targets).serialized
        }
    }

    let database: any Database

    func lookup(_ lookup: Lookup, sourceID: UUID) async throws -> ClinicalEventReceipt {
        let context = try AuthContext.checkIsParticipant()
        // Ownership remains mandatory after revocation. This is not the admission path.
        let source = try await SourceBindingService(database: database).find(id: sourceID)
        guard lookup.identifier.producerInstance == source.producerInstance,
              lookup.identifier.businessIdentifier.systemValue == source.eventIdentifierSystem else {
            throw ServerError.notFound("Event receipt not found")
        }
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        // Deliberately omit raw_bytes, projections and grants from the read.
        guard let row = try await sql.raw("""
            SELECT id, source_id, identifier_system, identifier_value, raw_sha256, target_intent, received_at, node_count
            FROM clinical_events WHERE source_id = \(bind: sourceID)
                AND identifier_system = \(bind: lookup.identifier.businessIdentifier.systemValue)
                AND identifier_value = \(bind: lookup.identifier.businessIdentifier.value)
            """)
            .first() else { throw ServerError.notFound("Event receipt not found") }
        guard try row.decode(column: "raw_sha256", as: String.self) == lookup.digest,
              try row.decode(column: "target_intent", as: String.self) == lookup.intent else {
            throw ServerError.conflict("Receipt does not match the original bytes or study targets")
        }
        let receipt = try ClinicalEventReceipt(row: row)
        return try await AuditRepository.disclose(.init(
            context: context.auditContext,
            action: .clinicalEventReceiptDisclosure,
            scope: .participantSource(participantID: source.participantID, sourceBindingID: sourceID),
            target: .init(id: receipt.eventID)
        ), on: database) { _ in receipt }
    }
}


extension ClinicalEventReceipt {
    init(row: any SQLRow) throws {
        try self.init(
            eventID: row.decode(column: "id", as: UUID.self),
            sourceID: row.decode(column: "source_id", as: UUID.self),
            producerEventIdentifier: .init(
                system: row.decode(column: "identifier_system", as: String.self),
                value: row.decode(column: "identifier_value", as: String.self)
            ),
            payloadSHA256: row.decode(column: "raw_sha256", as: String.self),
            targetIntentSHA256: SHA256.hash(data: Data(row.decode(column: "target_intent", as: String.self).utf8))
                .map { String(format: "%02x", $0) }
                .joined(),
            receivedAt: row.decode(column: "received_at", as: Date.self),
            nodeCount: row.decode(column: "node_count", as: Int.self)
        )
    }
}
