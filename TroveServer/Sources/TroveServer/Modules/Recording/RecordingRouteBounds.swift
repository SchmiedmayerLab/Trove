//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract


/// Measurement bounds derived from every row, without retaining the recording in memory.
struct RecordingRouteBounds: Sendable {
    private(set) var first: Date?
    private(set) var last: Date?
    /// Present only for a query-created batch of independent rows.
    private(set) var rows: RecordingRowExtent?

    init() {}

    /// Reconstructs receiver-verified bounds from the immutable custody ledger.
    init(first: Date?, last: Date?, rows: RecordingRowExtent? = nil) throws {
        switch (first, last) {
        case (nil, nil): break
        case let (first?, last?) where CollectionMeasurementWindow.valid(first)
            && CollectionMeasurementWindow.valid(last) && first <= last: break
        default: throw FHIRValidationClient.invalid
        }
        self.first = first
        self.last = last
        self.rows = rows
    }

    mutating func include(_ row: RecordingCSVReader.Row, format: RegisteredRecordingFormat = .locationTrackSamples) throws {
        let lower: Date?, upper: Date?
        switch format {
        case .pedometerSamples, .odometerSamples:
            lower = try row.timestamp("start")
            upper = try row.timestamp("end")
        default:
            lower = try row.timestamp("timestamp")
            upper = lower
        }
        guard let lower, let upper, CollectionMeasurementWindow.valid(lower), CollectionMeasurementWindow.valid(upper), lower <= upper else {
            throw FHIRValidationClient.invalid
        }
        if format == .beatIntervalSeries {
            guard let gap = try row.integer("precededByGap"), (0...1).contains(gap),
                  last.map({ lower >= $0 }) ?? true else { throw FHIRValidationClient.invalid }
        }
        first = first.map { min($0, lower) } ?? lower
        last = last.map { max($0, upper) } ?? upper
        if RecordingRowExtent.applies(to: format) {
            var extent = rows ?? RecordingRowExtent()
            try extent.include(row, format: format)
            rows = extent
        }
    }
}
