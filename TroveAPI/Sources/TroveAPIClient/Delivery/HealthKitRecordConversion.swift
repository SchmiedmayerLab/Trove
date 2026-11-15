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
    /// Records prepared under earlier collection authority, including attempts whose custody may
    /// be uncertain. This index survives delivery pruning; it never authorizes another active record.
    public func previouslyConvertedHealthKitRecords(_ recordIDs: [UUID], from expected: Checkpoint) throws -> [UUID] {
        try Task.checkCancellation()
        guard expected.scope == scope else { throw JournalError.wrongScope }
        guard recordIDs.count <= 128, Set(recordIDs).count == recordIDs.count else { throw JournalError.invalidConfiguration }
        return try database.transaction {
            _ = try activeSource(expected.sourceID)
            try validateCheckpoint(expected)
            guard !recordIDs.isEmpty else {
                return []
            }
            let placeholders = Array(repeating: "?", count: recordIDs.count).joined(separator: ", ")
            let rows = try database.query(
                "SELECT DISTINCT record_id FROM healthkit_record_conversion WHERE source_id = ? AND record_id IN (\(placeholders))",
                [.text(expected.sourceID.uuidString.lowercased())] + recordIDs.map { .text($0.uuidString.lowercased()) }
            ) { try Self.identifier($0, 0) }
            let known = Set(rows)
            try Task.checkCancellation()
            return recordIDs.filter { known.contains($0) }
        }
    }

    /// Re-querying an unchanged HealthKit object, including across overlapping intervals, keeps
    /// its first conversion instant. The configuration includes converter and source-revision facts;
    /// changed facts start a new conversion without changing the object's native UUID.
    /// Retain this small index after delivery so later backfills do not manufacture new versions.
    public func healthKitConversionInstants(
        for recordIDs: [UUID], configuration: Data, from expected: Checkpoint, at instant: Date
    ) throws -> [UUID: Date] {
        try Task.checkCancellation()
        guard expected.scope == scope else { throw JournalError.wrongScope }
        guard (1...16_384).contains(configuration.count), recordIDs.count <= 128, Set(recordIDs).count == recordIDs.count,
              (0...253_402_300_799).contains(instant.timeIntervalSince1970) else { throw JournalError.invalidConfiguration }
        let digest = SHA256.hash(data: configuration).map { String(format: "%02x", $0) }.joined()
        return try database.transaction {
            _ = try activeSource(expected.sourceID)
            try validateCheckpoint(expected)
            var result: [UUID: Date] = [:]
            let rounded = (instant.timeIntervalSince1970 * 1000).rounded(.toNearestOrEven) / 1000
            for id in recordIDs {
                let parameters: [DeliverySQLite.Value] = [
                    .text(expected.sourceID.uuidString.lowercased()), .text(id.uuidString.lowercased()), .text(digest)
                ]
                try database.execute(
                    """
                    INSERT INTO healthkit_record_conversion(source_id, record_id, configuration, recorded_at) VALUES (?, ?, ?, ?)
                    ON CONFLICT(source_id, record_id, configuration) DO NOTHING
                    """, parameters + [.real(rounded)]
                )
                let dates = try database.query(
                    "SELECT recorded_at FROM healthkit_record_conversion WHERE source_id = ? AND record_id = ? AND configuration = ?", parameters
                ) { sqlite3_column_double($0, 0) }
                guard let date = dates.first, (0...253_402_300_799).contains(date) else { throw JournalError.corruptJournal }
                result[id] = Date(timeIntervalSince1970: date)
            }
            try checkByteLimit()
            try Task.checkCancellation()
            return result
        }
    }
}
