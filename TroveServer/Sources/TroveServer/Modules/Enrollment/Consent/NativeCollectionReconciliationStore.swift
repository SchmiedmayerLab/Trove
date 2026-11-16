//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import SQLKit
import TroveAPIServer
import TroveAPITypes


/// Caller holds participant then enrollment locks; completed scope is never restarted by a lease refresh.
struct NativeCollectionReconciliationStore {
    typealias Instruction = Components.Schemas.NativeCollectionReconciliationInstruction

    let database: any SQLDatabase
    let participantID: UUID

    /// Retained at the wire's microsecond precision: the installation compares the window with its plan exactly.
    private static func encode(_ value: Instruction) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(TroveDateTranscoder().encode(date))
        }
        let bytes = try encoder.encode(value)
        guard bytes.count <= 16_384, let string = String(data: bytes, encoding: .utf8) else { throw ServerError.unexpectedError }
        return string
    }

    private static func decode(_ string: String) throws -> Instruction {
        guard string.utf8.count <= 16_384 else { throw ServerError.unexpectedError }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { try TroveDateTranscoder().decode($0.singleValueContainer().decode(String.self)) }
        return try decoder.decode(Instruction.self, from: Data(string.utf8))
    }

    /// Issuance and expiration are lease facts, not new clinical scopes or sweep identities.
    private static func scopeKey(_ value: Instruction) throws -> String {
        var fixed = value
        fixed.id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)).uuidString.lowercased()
        fixed.issuedAt = Date(timeIntervalSince1970: 0)
        fixed.expiresAt = fixed.issuedAt
        return try SHA256.hash(data: Data(encode(fixed).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func issue(_ candidate: Instruction) async throws -> Instruction? {
        let key = try Self.scopeKey(candidate)
        let sourceID = try candidate.sourceId.requireId(), enrollmentID = try candidate.enrollmentId.requireId()
        try await database.raw("""
            INSERT INTO native_collection_reconciliations (id, source_id, enrollment_id, study_id, participant_id, scope_key, instruction)
            VALUES (\(bind: try candidate.id.requireId()), \(bind: sourceID), \(bind: enrollmentID),
                \(bind: try candidate.studyId.requireId()), \(bind: participantID), \(bind: key), \(bind: try Self.encode(candidate)))
            ON CONFLICT (source_id, enrollment_id, scope_key) DO NOTHING
            """)
            .run()
        guard let row = try await database.raw("""
            SELECT id, instruction, completed_at FROM native_collection_reconciliations
            WHERE source_id = \(bind: sourceID) AND enrollment_id = \(bind: enrollmentID) AND scope_key = \(bind: key)
            """)
            .first() else { throw ServerError.unexpectedError }
        guard try row.decode(column: "completed_at", as: Date?.self) == nil else {
            return nil
        }
        var retained = try Self.decode(row.decode(column: "instruction", as: String.self))
        guard try Self.scopeKey(retained) == key else { throw ServerError.unexpectedError }
        retained.issuedAt = candidate.issuedAt
        retained.expiresAt = candidate.expiresAt
        try await database.raw("""
            UPDATE native_collection_reconciliations SET instruction = \(bind: try Self.encode(retained))
            WHERE id = \(bind: try retained.id.requireId()) AND completed_at IS NULL
            """)
            .run()
        return retained
    }

    /// This acknowledges a finite acquisition sweep, never delivery or indefinite historical completeness.
    func complete(id: UUID, sourceID: UUID, enrollmentID: UUID, now: Date) async throws {
        guard let row = try await database.raw("""
            SELECT id FROM native_collection_reconciliations
            WHERE id = \(bind: id) AND source_id = \(bind: sourceID) AND enrollment_id = \(bind: enrollmentID)
            """)
            .first() else { throw ServerError.notFound("Collection reconciliation not found") }
        _ = try row.decode(column: "id", as: UUID.self)
        try await database.raw("""
            UPDATE native_collection_reconciliations SET completed_at = COALESCE(completed_at, \(bind: now))
            WHERE id = \(bind: id) AND source_id = \(bind: sourceID) AND enrollment_id = \(bind: enrollmentID)
            """)
            .run()
    }
}
