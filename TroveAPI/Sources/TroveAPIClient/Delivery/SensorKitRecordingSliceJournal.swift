//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import CTroveDeliverySQLite
import Foundation


extension DeliveryJournal where Contract == TroveDeliveryContract {
    /// Retained coverage is not removed when a study withdraws or its collection window changes.
    public func sensorKitRecordingSlices(
        sourceID: UUID, sourceTypeIdentifier: String, deviceProductType: String, coordinate: String
    ) throws -> [SensorKitRecordingSlice] {
        try requireSensorKitSource(sourceID)
        return try database.query("""
            SELECT s.row_start, s.row_end, s.source_record_id, s.sha256
            FROM sensorkit_recording_slice s JOIN sensorkit_batch_evidence b ON b.id = s.batch_id
            WHERE b.source_id = ? AND b.source_type_identifier = ? AND b.device_product_type = ? AND b.coordinate = ?
            ORDER BY s.row_start
            """, [
                .text(sourceID.uuidString.lowercased()), .text(sourceTypeIdentifier), .text(deviceProductType), .text(coordinate)
            ]) { statement in
                guard let id = try UUID(uuidString: DeliverySQLite.text(statement, 2)) else { throw JournalError.corruptJournal }
                return try SensorKitRecordingSlice(
                    rows: Int(sqlite3_column_int64(statement, 0))..<Int(sqlite3_column_int64(statement, 1)),
                    sourceRecordID: id,
                    contentDigest: DeliverySQLite.blob(statement, 3)
                )
        }
    }

    func retainSensorKitRecordingSlices(
        _ slices: [SensorKitRecordingSlice], sourceID: UUID, evidence: SensorKitBatchEvidence
    ) throws {
        guard slices.count <= limits.maximumRecordingFiles else { throw JournalError.capacityExceeded }
        let batchID = try sensorKitEvidencePosition(
            sourceID: sourceID,
            sourceTypeIdentifier: evidence.sourceTypeIdentifier,
            deviceProductType: evidence.deviceProductType,
            coordinate: evidence.coordinate
        )
        for slice in slices {
            let overlapping = try database.query("""
                SELECT row_start, row_end, source_record_id, sha256 FROM sensorkit_recording_slice
                WHERE batch_id = ? AND row_start < ? AND row_end > ?
                """, [.integer(batchID), .integer(Int64(slice.rows.upperBound)), .integer(Int64(slice.rows.lowerBound))]) { statement in
                    try SensorKitRecordingSlice(
                        rows: Int(sqlite3_column_int64(statement, 0))..<Int(sqlite3_column_int64(statement, 1)),
                        sourceRecordID: Self.identifier(statement, 2),
                        contentDigest: DeliverySQLite.blob(statement, 3)
                    )
            }
            if !overlapping.isEmpty {
                guard overlapping == [slice] else { throw JournalError.eventIdentityMismatch }
                continue
            }
            try database.execute("""
                INSERT INTO sensorkit_recording_slice(batch_id, row_start, row_end, source_record_id, sha256) VALUES (?, ?, ?, ?, ?)
                """, [
                    .integer(batchID), .integer(Int64(slice.rows.lowerBound)), .integer(Int64(slice.rows.upperBound)),
                    .text(slice.sourceRecordID.uuidString.lowercased()), .blob(slice.contentDigest)
                ])
        }
    }
}
