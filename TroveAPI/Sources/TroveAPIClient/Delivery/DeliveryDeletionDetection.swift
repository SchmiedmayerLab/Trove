//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import CTroveDeliverySQLite
import Foundation


extension DeliveryJournal {
    /// Freezes the observed upper bound before a retraction is minted. A failed export or
    /// restart reuses it; successful staging retires it with the payloads and next cursor.
    public func deletionDetections(
        for recordIDs: [UUID], from expected: Checkpoint, at instant: Date
    ) throws -> [UUID: Date] {
        guard expected.scope == scope else { throw JournalError.wrongScope }
        guard recordIDs.count <= 128, Set(recordIDs).count == recordIDs.count,
              (0...253_402_300_799).contains(instant.timeIntervalSince1970) else {
            throw JournalError.invalidConfiguration
        }
        return try database.transaction {
            _ = try activeSource(expected.sourceID)
            guard try checkpoint(for: expected.sourceID) == expected else { throw JournalError.staleCheckpoint }
            var detections: [UUID: Date] = [:]
            for id in recordIDs {
                let parameters: [DeliverySQLite.Value] = [
                    .text(expected.sourceID.uuidString.lowercased()), .text(id.uuidString.lowercased())
                ]
                try database.execute(
                    """
                    INSERT INTO deletion_detection(source_id, record_id, detected_at) VALUES (?, ?, ?)
                    ON CONFLICT(source_id, record_id) DO NOTHING
                    """, parameters + [.real(instant.timeIntervalSince1970)]
                )
                let dates = try database.query(
                    "SELECT detected_at FROM deletion_detection WHERE source_id = ? AND record_id = ?", parameters
                ) { sqlite3_column_double($0, 0) }
                guard let date = dates.first else { throw JournalError.corruptJournal }
                detections[id] = Date(timeIntervalSince1970: date)
            }
            let counts = try database.query("SELECT count(*) FROM deletion_detection") { sqlite3_column_int64($0, 0) }
            guard let count = counts.first, count <= limits.maximumEvents else { throw JournalError.capacityExceeded }
            try checkByteLimit()
            return detections
        }
    }
}
