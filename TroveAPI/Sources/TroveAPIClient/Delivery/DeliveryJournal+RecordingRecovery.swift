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
    private static func fileReservation(_ statement: OpaquePointer) throws -> DeliveryFileStore.Reservation {
        .init(id: try identifier(statement, 0), device: try DeliverySQLite.text(statement, 1), inode: try DeliverySQLite.text(statement, 2))
    }

    /// Retained file commitments remain available after custody and file deletion until the delivery is pruned.
    public func recordingReferences(for deliveryID: UUID) throws -> [DeliveryRecordingReference] {
        try database.query("""
            SELECT files.id, relative_path, byte_count, sha256, files.source_id, delivery.source_id
            FROM recording_file files JOIN delivery ON delivery.id = files.delivery_id
            WHERE delivery_id = ? ORDER BY relative_path
            """, [.text(deliveryID.uuidString.lowercased())]) { statement in
                let path = try DeliverySQLite.text(statement, 1), digest = try DeliverySQLite.text(statement, 3)
                let count = sqlite3_column_int64(statement, 2)
                guard Self.validRecordingPath(path), (1...Int64(Int32.max)).contains(count),
                      digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      try Self.identifier(statement, 4) == Self.identifier(statement, 5) else { throw JournalError.corruptJournal }
                return .init(id: try Self.identifier(statement, 0), relativePath: path, byteCount: Int(count), sha256: digest)
        }
    }

    /// Read-only locator for a pending recording. Take an immutable snapshot and verify its retained digest before upload.
    /// This checks inode ownership and size; callers must not modify or delete queue-owned files.
    public func recordingURL(for recordingID: UUID) throws -> URL {
        let rows = try database.query("""
            SELECT files.id, device, inode, byte_count FROM recording_file files
            JOIN delivery ON delivery.id = files.delivery_id
            WHERE files.id = ? AND state = 'attached' AND receipt IS NULL
                AND files.source_id = delivery.source_id
            """, [.text(recordingID.uuidString.lowercased())]) {
            (try Self.fileReservation($0), sqlite3_column_int64($0, 3))
        }
        guard let (reservation, count) = rows.first, (1...Int64(Int32.max)).contains(count) else { throw JournalError.unknownDelivery }
        return try recordingFiles.verifiedURL(reservation, byteCount: Int(count))
    }

    /// Reclaims only known abandoned reservations or files whose clinical custody receipt committed.
    /// SQLite's writer lock prevents cleanup from racing a staging transaction in another process.
    @discardableResult
    public func reclaimRecordingFiles(limit: Int = 128) throws -> Int {
        guard (1...128).contains(limit) else { throw JournalError.invalidConfiguration }
        return try database.transaction {
            let rows = try database.query("""
                SELECT id, device, inode, delivery_id FROM recording_file
                WHERE state IN ('reserved', 'retired') ORDER BY rowid LIMIT ?
                """, [.integer(Int64(limit))]) {
                    (try Self.fileReservation($0), sqlite3_column_type($0, 3) != SQLITE_NULL)
            }
            for (reservation, hasDelivery) in rows {
                try recordingFiles.remove(reservation)
                if hasDelivery {
                    try database.execute("UPDATE recording_file SET state = 'deleted' WHERE id = ?", [.text(reservation.id.uuidString.lowercased())])
                } else {
                    try database.execute("DELETE FROM recording_file WHERE id = ?", [.text(reservation.id.uuidString.lowercased())])
                }
            }
            return rows.count
        }
    }
}
