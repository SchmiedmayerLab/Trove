//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIClient


/// Plans immutable ranges over ordered replay evidence, without a per-row persistence table.
enum SensorKitSliceSelection {
    static func ranges(
        count: Int, retained: [SensorKitRecordingSlice], maximumSlices: Int, authorized: (Int) throws -> Bool
    ) throws -> [Range<Int>] {
        guard count >= 0, maximumSlices > 0 else { throw SensorKitAcquisition.AcquisitionError.invalidBatch }
        let covered = retained.map(\.rows).sorted { $0.lowerBound < $1.lowerBound }
        guard covered.allSatisfy({ !$0.isEmpty && $0.lowerBound >= 0 && $0.upperBound <= count }),
              zip(covered, covered.dropFirst()).allSatisfy({ $0.upperBound <= $1.lowerBound }) else {
            throw SensorKitAcquisition.AcquisitionError.retryMismatch
        }
        var result: [Range<Int>] = []
        var cursor = 0
        for range in covered {
            try appendUncovered(cursor..<range.lowerBound, to: &result, maximumSlices: maximumSlices, authorized: authorized)
            if try range.allSatisfy(authorized) { try append(range, to: &result, maximumSlices: maximumSlices) }
            cursor = range.upperBound
        }
        try appendUncovered(cursor..<count, to: &result, maximumSlices: maximumSlices, authorized: authorized)
        return result
    }

    private static func appendUncovered(
        _ range: Range<Int>, to result: inout [Range<Int>], maximumSlices: Int, authorized: (Int) throws -> Bool
    ) throws {
        var start: Int?
        for row in range {
            if try authorized(row) {
                if start == nil { start = row }
            } else if let lower = start {
                try append(lower..<row, to: &result, maximumSlices: maximumSlices)
                start = nil
            }
        }
        if let start { try append(start..<range.upperBound, to: &result, maximumSlices: maximumSlices) }
    }

    private static func append(_ range: Range<Int>, to result: inout [Range<Int>], maximumSlices: Int) throws {
        guard result.count < maximumSlices else { throw EventDeliveryJournal.JournalError.capacityExceeded }
        result.append(range)
    }
}
