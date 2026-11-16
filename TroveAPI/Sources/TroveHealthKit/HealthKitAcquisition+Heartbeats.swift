// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

#if canImport(HealthKit)

import Foundation
import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit


extension HealthKitAcquisition {
    /// One complete series per page. Grove pulls the SDK sequence into a bounded immutable file;
    /// no beat array or CSV buffer accumulates in the client. Consent is checked before invoking the reader.
    static func queryHeartbeats(
        _ healthKit: GroveHealthKit.HealthKit, anchor: inout QueryAnchor, predicate: NSPredicate, maximumRecordingBytes: Int
    ) async throws -> Delta {
        let changes = try await healthKit.query(.heartbeatSeries, timeRange: .ever, anchor: &anchor, limit: 1, predicate: predicate)
        return Delta(
            added: changes.added,
            deletedIDs: changes.deleted.map(\.uuid),
            nextAnchor: anchor,
            readHeartbeatSeries: { series in
                let beats = HKHeartbeatSeriesQueryDescriptor(series).results(for: healthKit.healthStore).map { beat in
                    HealthKitFHIRExporter.Record.Heartbeat(timeSinceSeriesStart: beat.timeIntervalSinceStart, precededByGap: beat.precededByGap)
                }
                return try await HealthKitRecordingFile.heartbeatSeries(
                    series,
                    beats: beats,
                    relativePath: "recordings/\(series.uuid.uuidString.lowercased()).csv",
                    maximumByteCount: maximumRecordingBytes
                )
            }
        )
    }
}

#endif
