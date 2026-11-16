//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import ModelsR4
import Testing
@testable import TroveServer


struct RecordedInstantTests {
    struct Example: Sendable {
        let text: String
        let seconds: Int64
        let fraction: String
    }

    @Test(arguments: [
        Example(text: "1970-01-01T00:00:00Z", seconds: 0, fraction: ""),
        Example(text: "1969-12-31T23:59:59.999999999999999999Z", seconds: -1, fraction: "999999999999999999"),
        Example(text: "2026-11-13T12:00:00.000000000000000001+08:00", seconds: 1794542400, fraction: "000000000000000001"),
        Example(text: "2026-11-13T04:00:00.12000Z", seconds: 1794542400, fraction: "12")
    ])
    func preservesExactOrderingComponents(example: Example) throws {
        let result = try RecordedInstant(Instant(example.text))
        #expect(result.seconds == example.seconds)
        #expect(result.fraction == example.fraction)
    }

    @Test
    func equivalentOffsetsAndTrailingZerosCompareEqually() throws {
        let first = try RecordedInstant(Instant("2026-11-12T20:00:00.100-08:00"))
        let second = try RecordedInstant(Instant("2026-11-13T04:00:00.1Z"))
        #expect(first == second)
    }

    @Test
    func leapSecondsAreOutsidePinnedValidatorBoundary() throws {
        let instant = try Instant("2016-12-31T23:59:60Z")
        #expect(throws: (any Error).self) { try RecordedInstant(instant) }
    }

    @Test("Calendar normalization cannot change source or provenance evidence", arguments: [
        "2026-02-31T12:00:00.123456789Z", "2026-02-29T12:00:00+08:00", "2024-02-30T12:00:00-08:00",
        "2026-04-31T00:00:00Z", "2026-11-01T00:00:00-00:00"
    ])
    func rejectsInvalidCalendarAndUnknownOffset(_ value: String) {
        #expect(throws: (any Error).self) { try RecordedInstant(Instant(value)) }
        #expect(throws: (any Error).self) { try ClinicalMeasurementBounds(sourceStart: value) }
    }

    @Test("Gregorian leap days preserve exact source fractional ordering")
    func leapDay() throws {
        let first = try ClinicalMeasurementBounds(sourceStart: "2024-02-29T23:59:59.999999999+08:00")
        let second = try ClinicalMeasurementBounds(sourceStart: "2024-03-01T00:00:00+08:00")
        #expect(first.start < second.start)
        #expect(first.start.fraction == "999999999")
    }
}
