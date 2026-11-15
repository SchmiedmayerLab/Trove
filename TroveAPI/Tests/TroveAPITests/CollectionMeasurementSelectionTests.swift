//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPITypes


struct CollectionMeasurementSelectionTests {
    @Test(arguments: [
        (-10.0, 0.0, false), (-10, 1, true), (-10, 20, true), (0, 1, true), (9, 20, true), (10, 20, false),
        (0, 0, true), (10, 10, false), (5, 4, false)
    ])
    func selectsWholeOverlappingIntervals(start: Double, end: Double, expected: Bool) {
        #expect(CollectionMeasurementSelection.includes(
            sampleStart: Date(timeIntervalSince1970: start),
            sampleEnd: Date(timeIntervalSince1970: end),
            windowStart: Date(timeIntervalSince1970: 0),
            windowEnd: Date(timeIntervalSince1970: 10)
        ) == expected)
    }

    @Test(arguments: [-1.0, 0, 9, 10])
    func keepsPointWindowsHalfOpen(instant: Double) {
        #expect(CollectionMeasurementSelection.includes(
            sampleStart: Date(timeIntervalSince1970: instant),
            sampleEnd: nil,
            windowStart: Date(timeIntervalSince1970: 0),
            windowEnd: Date(timeIntervalSince1970: 10)
        ) == (instant >= 0 && instant < 10))
    }

    @Test(arguments: [0.0, -1, .infinity, .nan])
    func refusesEmptyReversedOrNonfiniteWindows(end: Double) {
        #expect(!CollectionMeasurementSelection.includes(
            sampleStart: Date(timeIntervalSince1970: -10),
            sampleEnd: Date(timeIntervalSince1970: 10),
            windowStart: Date(timeIntervalSince1970: 0),
            windowEnd: Date(timeIntervalSince1970: end)
        ))
    }

    @Test
    func permitsOpenEndedCollectionAndPreservesFractionalBoundary() {
        let boundary = Date(timeIntervalSince1970: 1_750_000_000.123456)
        #expect(CollectionMeasurementSelection.includes(
            sampleStart: boundary.addingTimeInterval(-1),
            sampleEnd: boundary.addingTimeInterval(0.000_001),
            windowStart: boundary,
            windowEnd: nil
        ))
        #expect(!CollectionMeasurementSelection.includes(
            sampleStart: boundary.addingTimeInterval(-1),
            sampleEnd: boundary,
            windowStart: boundary,
            windowEnd: nil
        ))
    }
}
