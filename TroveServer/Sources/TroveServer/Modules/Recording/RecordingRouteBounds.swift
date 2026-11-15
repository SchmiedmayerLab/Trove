//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract


/// Measurement bounds derived from every row, without retaining the route in memory.
struct RecordingRouteBounds: Sendable {
    private(set) var first: Date?
    private(set) var last: Date?

    init() {}

    /// Reconstructs receiver-verified bounds from the immutable custody ledger.
    init(first: Date?, last: Date?) throws {
        switch (first, last) {
        case (nil, nil): break
        case let (first?, last?) where CollectionMeasurementWindow.valid(first)
            && CollectionMeasurementWindow.valid(last) && first <= last: break
        default: throw FHIRValidationClient.invalid
        }
        self.first = first
        self.last = last
    }

    mutating func include(_ row: RecordingCSVReader.Row) throws {
        guard let instant = try row.timestamp("timestamp"), CollectionMeasurementWindow.valid(instant) else {
            throw FHIRValidationClient.invalid
        }
        first = first.map { min($0, instant) } ?? instant
        last = last.map { max($0, instant) } ?? instant
    }
}
