//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract


/// Exact row extremes of a query-created recording batch. Its rows are independent measurements,
/// so the batch envelope is not one native session: a collection window selects the recording
/// only when it selects every row. This value is receiver evidence; it grants no access by itself.
struct RecordingRowExtent: Sendable, Equatable, Codable {
    /// The earliest row without a duration.
    private(set) var earliestPoint: RecordedInstant?
    /// The earliest end among rows that carry a native interval.
    private(set) var earliestIntervalEnd: RecordedInstant?
    private(set) var latestStart: RecordedInstant?

    /// Registered formats whose rows are fetched in arbitrary batches instead of one native session.
    static func applies(to format: RegisteredRecordingFormat) -> Bool {
        switch format {
        case .ambientLightSamples, .ambientPressureSamples, .deviceMotionSamples, .headphoneSettingsSamples,
             .heartRateSamples, .odometerSamples, .pedometerSamples, .triaxialAccelerationSamples, .triaxialRotationSamples:
            true
        default: false
        }
    }

    /// The registered CSV reader validates canonical numeric grammar before these exact lexemes are compared.
    mutating func include(_ row: RecordingCSVReader.Row, format: RegisteredRecordingFormat) throws {
        guard Self.applies(to: format) else { throw FHIRValidationClient.invalid }
        let isInterval = format == .pedometerSamples || format == .odometerSamples
        let start = try Self.instant(row[isInterval ? "start" : "timestamp"])
        let end = isInterval ? try Self.instant(row["end"]) : start
        guard end >= start else { throw FHIRValidationClient.invalid }
        if end > start {
            earliestIntervalEnd = earliestIntervalEnd.map { min($0, end) } ?? end
        } else {
            earliestPoint = earliestPoint.map { min($0, start) } ?? start
        }
        latestStart = latestStart.map { max($0, start) } ?? start
    }

    /// Point rows are selected half-open; a row with a native interval is selected whole when it overlaps.
    /// A recording without rows is never selected.
    func isSelected(windowStart: Date, windowEnd: Date?) throws -> Bool {
        guard let latestStart else {
            return false
        }
        let lower = try RecordedInstant(authorityDate: windowStart)
        let upper = try windowEnd.map { try RecordedInstant(authorityDate: $0) }
        return (upper.map { $0 > lower && latestStart < $0 } ?? true)
            && (earliestPoint.map { $0 >= lower } ?? true)
            && (earliestIntervalEnd.map { $0 > lower } ?? true)
    }
}


extension RecordingRowExtent {
    private static func instant(_ value: String?) throws -> RecordedInstant {
        guard let value else { throw FHIRValidationClient.invalid }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let seconds = Int64(parts[0]), (0...253_402_300_799).contains(seconds) else {
            throw FHIRValidationClient.invalid
        }
        var fraction = parts.count == 2 ? String(parts[1]) : ""
        guard parts.count == 1 || !fraction.isEmpty, fraction.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw FHIRValidationClient.invalid
        }
        while fraction.last == "0" { fraction.removeLast() }
        return RecordedInstant(seconds: seconds, fraction: fraction)
    }
}
