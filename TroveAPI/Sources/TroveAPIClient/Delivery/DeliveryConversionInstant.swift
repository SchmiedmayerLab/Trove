//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


extension DeliveryJournal {
    /// Keep the conversion's recorded time stable while a query checkpoint is retried.
    /// Grove's producer is stateless; staged record bytes and versions belong to this journal.
    public func conversionInstant(from expected: Checkpoint, at now: Date = .now) throws -> Date {
        try Task.checkCancellation()
        guard expected.scope == scope else { throw JournalError.wrongScope }
        guard (0...253_402_300_799).contains(now.timeIntervalSince1970) else { throw JournalError.invalidConfiguration }
        return try database.transaction {
            _ = try activeSource(expected.sourceID)
            try validateCheckpoint(expected)
            let queryID = expected.queryID.uuidString.lowercased()
            let rows = try database.query(
                "SELECT conversion_instant FROM acquisition_query WHERE id = ? AND conversion_instant IS NOT NULL", [.text(queryID)]
            ) { try DeliverySQLite.blob($0, 0) }
            if let bytes = rows.first {
                guard let instant = try? JSONDecoder().decode(Date.self, from: bytes),
                      (0...253_402_300_799).contains(instant.timeIntervalSince1970) else { throw JournalError.corruptJournal }
                return instant
            }
            let instant = Date(timeIntervalSince1970: (now.timeIntervalSince1970 * 1000).rounded(.toNearestOrEven) / 1000)
            let bytes = try JSONEncoder().encode(instant)
            try database.execute(
                "UPDATE acquisition_query SET conversion_instant = ? WHERE id = ?", [.blob(bytes), .text(queryID)]
            )
            try checkByteLimit()
            try Task.checkCancellation()
            return try JSONDecoder().decode(Date.self, from: bytes)
        }
    }
}
