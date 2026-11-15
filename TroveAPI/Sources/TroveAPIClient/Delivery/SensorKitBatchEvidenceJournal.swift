//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import CTroveDeliverySQLite
import Foundation


extension DeliveryJournal where Contract == TroveDeliveryContract {
    /// Retains first-acquisition facts and the exact replay token atomically with the prepared cursor.
    /// A conflicting repeat never replaces the original evidence or advances the checkpoint.
    public func prepareSensorKitBatch(
        from expected: Checkpoint, nextCursor: Data, evidence: SensorKitBatchEvidence
    ) throws {
        let content = try evidence.encoded()
        _ = try stage(from: expected, nextCursor: nextCursor, payloads: []) { _ in
            try requireSensorKitSource(expected.sourceID)
            let keys: [DeliverySQLite.Value] = [
                .text(expected.sourceID.uuidString.lowercased()), .text(evidence.sourceTypeIdentifier),
                .text(evidence.deviceProductType), .text(evidence.coordinate)
            ]
            let prior = try database.query("""
                SELECT content FROM sensorkit_batch_evidence
                WHERE source_id = ? AND source_type_identifier = ? AND device_product_type = ? AND coordinate = ?
                """, keys) { try DeliverySQLite.blob($0, 0) }
            if let prior = prior.first {
                guard prior == content else { throw JournalError.eventIdentityMismatch }
                return
            }
            try database.execute("""
                INSERT INTO sensorkit_batch_evidence(source_id, source_type_identifier, device_product_type, coordinate,
                    effective_start, effective_end, content, sha256) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, keys + [
                    .real(evidence.effectiveStart.timeIntervalSince1970), .real(evidence.effectiveEnd.timeIntervalSince1970),
                    .blob(content), .text(Self.sensorKitEvidenceDigest(content))
                ])
        }
    }

    /// Reads the immutable first attempt before preparing a repeated native batch.
    public func sensorKitBatchEvidence(
        sourceID: UUID, sourceTypeIdentifier: String, deviceProductType: String, coordinate: String
    ) throws -> SensorKitBatchEvidence? {
        try requireSensorKitSource(sourceID)
        return try database.query("""
            SELECT content, sha256 FROM sensorkit_batch_evidence
            WHERE source_id = ? AND source_type_identifier = ? AND device_product_type = ? AND coordinate = ?
            """, [
                .text(sourceID.uuidString.lowercased()), .text(sourceTypeIdentifier), .text(deviceProductType), .text(coordinate)
            ]) { statement in
                let evidence = try Self.decodeSensorKitEvidence(statement)
                guard evidence.sourceTypeIdentifier == sourceTypeIdentifier, evidence.deviceProductType == deviceProductType,
                      evidence.coordinate == coordinate else { throw JournalError.corruptJournal }
                return evidence
        }.first
    }

    /// Bounded pages keep historical replay independent of the live source cursor.
    /// Retained evidence is never pruned automatically; callers can expose its usage and budget refusal.
    public func sensorKitBatchEvidencePage(
        sourceID: UUID, sourceTypeIdentifier: String, deviceProductType: String? = nil, after rowID: Int64 = 0, limit: Int = 32
    ) throws -> [SensorKitRetainedBatch] {
        guard rowID >= 0, (1...128).contains(limit) else { throw JournalError.invalidConfiguration }
        try requireSensorKitSource(sourceID)
        return try database.query("""
            SELECT content, sha256, id, staged_authority FROM sensorkit_batch_evidence
            WHERE source_id = ? AND source_type_identifier = ? AND (? IS NULL OR device_product_type = ?) AND id > ? ORDER BY id LIMIT ?
            """, [
                .text(sourceID.uuidString.lowercased()), .text(sourceTypeIdentifier),
                deviceProductType.map(DeliverySQLite.Value.text) ?? .null, deviceProductType.map(DeliverySQLite.Value.text) ?? .null,
                .integer(rowID), .integer(Int64(limit))
            ]) {
                let evidence = try Self.decodeSensorKitEvidence($0)
                guard evidence.sourceTypeIdentifier == sourceTypeIdentifier,
                      deviceProductType.map({ $0 == evidence.deviceProductType }) ?? true else { throw JournalError.corruptJournal }
                let authority = sqlite3_column_type($0, 3) == SQLITE_NULL ? nil : try DeliverySQLite.text($0, 3)
                return SensorKitRetainedBatch(rowID: sqlite3_column_int64($0, 2), evidence: evidence, stagedAuthority: authority)
        }
    }

    /// Total retained replay rows and their contribution to the logical journal budget.
    public func sensorKitEvidenceUsage(sourceID: UUID) throws -> (batches: Int64, retainedBytes: Int64) {
        try requireSensorKitSource(sourceID)
        let rows = try database.query("""
            SELECT count(*), coalesce(sum(length(content) + length(source_type_identifier)
                + length(device_product_type) + length(coordinate) + 192), 0)
            FROM sensorkit_batch_evidence WHERE source_id = ?
            """, [.text(sourceID.uuidString.lowercased())]) { (sqlite3_column_int64($0, 0), sqlite3_column_int64($0, 1)) }
        guard let result = rows.first else { throw JournalError.corruptJournal }
        return result
    }

    func requireSensorKitSource(_ sourceID: UUID) throws {
        guard try activeSource(sourceID).binding?.source.repositoryKind == .sensorkit else { throw JournalError.sourceConflict }
    }
}


extension DeliveryJournal where Contract == TroveDeliveryContract {
    private static func sensorKitEvidenceDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func decodeSensorKitEvidence(_ statement: OpaquePointer) throws -> SensorKitBatchEvidence {
        let content = try DeliverySQLite.blob(statement, 0)
        guard try sensorKitEvidenceDigest(content) == DeliverySQLite.text(statement, 1) else { throw JournalError.corruptJournal }
        return try SensorKitBatchEvidence(encoded: content)
    }
}
