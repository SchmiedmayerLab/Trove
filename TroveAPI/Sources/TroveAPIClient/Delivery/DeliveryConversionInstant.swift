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
            guard try checkpoint(for: expected.sourceID) == expected else { throw JournalError.staleCheckpoint }
            let sourceID = expected.sourceID.uuidString.lowercased()
            let rows = try database.query(
                "SELECT value FROM producer_ledger WHERE source_id = ? AND key = 'conversion-instant'", [.text(sourceID)]
            ) { try DeliverySQLite.blob($0, 0) }
            if let bytes = rows.first {
                guard let instant = try? JSONDecoder().decode(Date.self, from: bytes),
                      (0...253_402_300_799).contains(instant.timeIntervalSince1970) else { throw JournalError.corruptJournal }
                return instant
            }
            let instant = Date(timeIntervalSince1970: (now.timeIntervalSince1970 * 1000).rounded(.toNearestOrEven) / 1000)
            let bytes = try JSONEncoder().encode(instant)
            try database.execute(
                "INSERT INTO producer_ledger(source_id, key, value) VALUES (?, 'conversion-instant', ?)", [.text(sourceID), .blob(bytes)]
            )
            try checkByteLimit()
            try Task.checkCancellation()
            return try JSONDecoder().decode(Date.self, from: bytes)
        }
    }
}
