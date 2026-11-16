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
    /// The queue's per-file budget, used by acquisition before constructing a recording.
    public var recordingByteLimit: Int { limits.maximumRecordingBytes }

    static func validRecordingPath(_ path: String) -> Bool {
        (1...512).contains(path.utf8.count)
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
            && path.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 47, 95].contains($0) }
    }

    /// Commit prepared payloads and their next cursor together. Grove owns wire identities;
    /// the queue sequence only orders local deliveries. Conversion must visit every change:
    /// omit explicit policy exclusions, but never advance past a malformed or refused record.
    /// A stale checkpoint requires reloading and querying again, never transforming the old result under a newer cursor.
    public func stage(
        from expected: Checkpoint,
        nextCursor: Data,
        payloads: [Payload],
        observedDeletions: [UUID] = [],
        queryExhausted: Bool = false
    ) throws -> [UUID] {
        try stage(
            from: expected,
            nextCursor: nextCursor,
            payloads: payloads,
            observedDeletions: observedDeletions,
            queryExhausted: queryExhausted,
            finalizingDeliveries: { _ in }
        )
    }

    func reserveRecordings(_ payloads: [Payload], from checkpoint: Checkpoint) throws -> [[DeliveryFileStore.Reservation]] {
        guard payloads.contains(where: { !$0.recordings.isEmpty }) else {
            return payloads.map { _ in [] }
        }
        let inputs = payloads.flatMap(\.recordings)
        guard payloads.allSatisfy({ $0.recordings.count <= 512 && Set($0.recordings.map(\.relativePath)).count == $0.recordings.count }),
              inputs.allSatisfy({ Self.validRecordingPath($0.relativePath) && (1...limits.maximumRecordingBytes).contains($0.byteCount) }) else {
            throw JournalError.invalidConfiguration
        }
        _ = try reclaimRecordingFiles()
        var created: [DeliveryFileStore.Reservation] = []
        do {
            return try database.transaction {
                _ = try activeDeliverySource(checkpoint.sourceID)
                try validateCheckpoint(checkpoint)
                try checkRecordingCapacity(adding: inputs)
                return try payloads.map { payload in
                    try payload.recordings.map { input in
                        let reservation = try recordingFiles.reserve()
                        created.append(reservation)
                        try database.execute("""
                            INSERT INTO recording_file(id, source_id, relative_path, device, inode, byte_count, state)
                            VALUES (?, ?, ?, ?, ?, ?, 'reserved')
                            """, [
                                .text(reservation.id.uuidString.lowercased()), .text(checkpoint.sourceID.uuidString.lowercased()),
                                .text(input.relativePath),
                                .text(reservation.device), .text(reservation.inode), .integer(Int64(input.byteCount))
                            ])
                        try checkByteLimit()
                        return reservation
                    }
                }
            }
        } catch {
            // These files are still empty; no recording bytes are written before reservation commit.
            for reservation in created { try? recordingFiles.remove(reservation) }
            throw error
        }
    }

    func writeRecordings(
        _ inputs: [DeliveryRecording], reservations: [DeliveryFileStore.Reservation], sourceID: UUID
    ) throws -> [DeliveryRecordingReference] {
        guard inputs.count == reservations.count else { throw JournalError.corruptJournal }
        return try zip(inputs, reservations).map { input, reservation in
            let rows = try database.query("""
                SELECT id FROM recording_file WHERE id = ? AND source_id = ? AND relative_path = ?
                    AND byte_count = ? AND device = ? AND inode = ? AND state = 'reserved'
                """, [
                    .text(reservation.id.uuidString.lowercased()), .text(sourceID.uuidString.lowercased()),
                    .text(input.relativePath), .integer(Int64(input.byteCount)),
                    .text(reservation.device), .text(reservation.inode)
                ]) { try Self.identifier($0, 0) }
            guard rows == [reservation.id] else { throw JournalError.corruptJournal }
            let digest = try recordingFiles.write(reservation, byteCount: input.byteCount, read: input.readChunks)
            return .init(id: reservation.id, relativePath: input.relativePath, byteCount: input.byteCount, sha256: digest)
        }
    }

    func attachRecordings(_ recordings: [DeliveryRecordingReference], to deliveryID: UUID) throws {
        for recording in recordings {
            try database.execute("UPDATE recording_file SET delivery_id = ?, sha256 = ?, state = 'attached' WHERE id = ? AND state = 'reserved'", [
                .text(deliveryID.uuidString.lowercased()), .text(recording.sha256), .text(recording.id.uuidString.lowercased())
            ])
        }
    }

    func matchRecordings(_ recordings: [DeliveryRecordingReference], to deliveryID: UUID) throws {
        let retained = try recordingReferences(for: deliveryID).sorted { $0.relativePath < $1.relativePath }
        let supplied = recordings.sorted { $0.relativePath < $1.relativePath }
        guard retained.count == supplied.count,
              zip(retained, supplied).allSatisfy({
                  $0.relativePath == $1.relativePath && $0.byteCount == $1.byteCount && $0.sha256 == $1.sha256
              }) else {
            throw JournalError.eventIdentityMismatch
        }
        for recording in recordings {
            try database.execute(
                "UPDATE recording_file SET state = 'retired' WHERE id = ? AND state = 'reserved'", [.text(recording.id.uuidString.lowercased())]
            )
        }
    }

    private func checkRecordingCapacity(adding inputs: [DeliveryRecording]) throws {
        let sizes = try database.query("""
            SELECT coalesce(sum(CASE WHEN state != 'deleted' THEN byte_count ELSE 0 END), 0), count(*) FROM recording_file
            """) { (sqlite3_column_int64($0, 0), sqlite3_column_int64($0, 1)) }
        guard let (bytes, files) = sizes.first, bytes >= 0, files >= 0,
              Int64(inputs.count) + files <= Int64(limits.maximumRecordingFiles),
              inputs.reduce(Int64(0), { $0 + Int64($1.byteCount) }) + bytes <= Int64(limits.maximumPendingRecordingBytes) else {
            throw JournalError.capacityExceeded
        }
    }
}
