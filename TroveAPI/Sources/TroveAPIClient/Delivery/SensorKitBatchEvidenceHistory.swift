//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import CTroveDeliverySQLite
import Foundation
import TroveAPITypes


extension DeliveryJournal where Contract == TroveDeliveryContract {
    /// Commits SensorKit payloads and first successfully staged authority before native acknowledgement.
    /// The immutable replay facts are unchanged. Repeated authority may skip only a durably completed conversion.
    public func stageSensorKitBatch(
        from expected: Checkpoint,
        nextCursor: Data,
        payloads: [Payload],
        evidence: SensorKitBatchEvidence,
        authority: String,
        recordingDeclarations: [[Components.Schemas.RecordingTransferDeclaration]] = [],
        recordingSlices: [SensorKitRecordingSlice] = []
    ) throws -> [UUID] {
        guard authority.utf8.count == 64,
              authority.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw JournalError.invalidConfiguration }
        let declarations = recordingDeclarations.isEmpty ? payloads.map { _ in [] } : recordingDeclarations
        return try stageRecordingPayloads(
            from: expected, nextCursor: nextCursor, payloads: payloads, recordingDeclarations: declarations
        ) { _ in
            let retained = try sensorKitBatchEvidence(
                sourceID: expected.sourceID,
                sourceTypeIdentifier: evidence.sourceTypeIdentifier,
                deviceProductType: evidence.deviceProductType,
                coordinate: evidence.coordinate
            )
            guard retained == evidence else { throw JournalError.eventIdentityMismatch }
            try retainSensorKitRecordingSlices(recordingSlices, sourceID: expected.sourceID, evidence: evidence)
            try database.execute("""
                UPDATE sensorkit_batch_evidence SET staged_authority = coalesce(staged_authority, ?)
                WHERE source_id = ? AND source_type_identifier = ? AND device_product_type = ? AND coordinate = ?
                """, [
                    .text(authority), .text(expected.sourceID.uuidString.lowercased()), .text(evidence.sourceTypeIdentifier),
                    .text(evidence.deviceProductType), .text(evidence.coordinate)
                ])
        }
    }

    /// Bounded distinct native partitions with retained replay evidence.
    public func sensorKitEvidenceDevices(sourceID: UUID, sourceTypeIdentifier: String) throws -> [String] {
        try requireSensorKitSource(sourceID)
        let devices = try database.query("""
            SELECT DISTINCT device_product_type FROM sensorkit_batch_evidence
            WHERE source_id = ? AND source_type_identifier = ? ORDER BY device_product_type LIMIT 129
            """, [.text(sourceID.uuidString.lowercased()), .text(sourceTypeIdentifier)]) { try DeliverySQLite.text($0, 0) }
        guard devices.count <= 128 else { throw JournalError.capacityExceeded }
        return devices
    }

    /// Resolves a committed replay receipt to its stable journal position; missing evidence is an error.
    public func sensorKitEvidencePosition(
        sourceID: UUID, sourceTypeIdentifier: String, deviceProductType: String, coordinate: String
    ) throws -> Int64 {
        guard try sensorKitBatchEvidence(
            sourceID: sourceID, sourceTypeIdentifier: sourceTypeIdentifier, deviceProductType: deviceProductType, coordinate: coordinate
        ) != nil else { throw JournalError.corruptJournal }
        let positions = try database.query("""
            SELECT id FROM sensorkit_batch_evidence
            WHERE source_id = ? AND source_type_identifier = ? AND device_product_type = ? AND coordinate = ?
            """, [
                .text(sourceID.uuidString.lowercased()), .text(sourceTypeIdentifier), .text(deviceProductType), .text(coordinate)
            ]) { sqlite3_column_int64($0, 0) }
        guard let position = positions.first, position > 0 else { throw JournalError.corruptJournal }
        return position
    }
}
