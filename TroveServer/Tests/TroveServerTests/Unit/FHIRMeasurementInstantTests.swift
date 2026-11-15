//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import ModelsR4
import Testing
import TroveAPITypes
@testable import TroveServer


struct FHIRMeasurementInstantTests {
    @Test("Source precision survives parsing, including independent source offsets")
    func preservesFraction() throws {
        let value = try FHIRMeasurementInstant.exact(DateTime("2026-11-01T00:00:00.000000001Z"))
        let equivalent = try FHIRMeasurementInstant.exact(DateTime("2026-10-31T17:00:00.000000001-07:00"))
        #expect(value == equivalent)
        #expect(value.fraction == "000000001")
        #expect(try FHIRMeasurementInstant.exact(DateTime("2026-11-01T00:00:00.123456789012Z")).fraction == "123456789012")
        #expect(try FHIRMeasurementInstant.exact(DateTime("2026-11-01T00:00:00.123000000Z")).fraction == "123")
    }

    @Test("A point is compared exactly on both sides of half-open authority boundaries", arguments: [
        ("2026-10-31T23:59:59.999999999Z", false), ("2026-11-01T00:00:00Z", true),
        ("2026-11-01T00:00:00.999999999Z", true), ("2026-11-01T00:00:01Z", false),
        ("2026-11-01T00:00:01.000000001Z", false)
    ])
    func pointBoundary(_ source: String, _ included: Bool) throws {
        let point = try ClinicalMeasurementBounds(sourceStart: source)
        #expect(try point.includes(windowStart: Self.lower, windowEnd: Self.upper, asOf: Self.upper) == included)
    }

    @Test("Whole sessions retain the exact overlap, without clipping or selecting touching intervals")
    func wholeSessionOverlap() throws {
        let crossing = try ClinicalMeasurementBounds(sourceStart: "2026-10-31T23:59:59Z", sourceEnd: "2026-11-01T00:00:00.000000001Z")
        let touching = try ClinicalMeasurementBounds(sourceStart: "2026-10-31T23:59:59Z", sourceEnd: "2026-11-01T00:00:00Z")
        #expect(try crossing.includes(windowStart: Self.lower, windowEnd: Self.upper, asOf: Self.upper))
        #expect(try !touching.includes(windowStart: Self.lower, windowEnd: Self.upper, asOf: Self.upper))
        #expect(crossing.start.seconds < Int64(try Self.lower.timeIntervalSince1970))
        #expect(try !crossing.includes(windowStart: Self.lower, windowEnd: Self.upper, asOf: Self.lower))
    }

    @Test("API microsecond authority is compared without rounding clinical evidence")
    func microsecondAuthority() throws {
        let boundary = try TroveDateTranscoder().decode("2026-11-01T00:00:00.123456Z")
        let before = try ClinicalMeasurementBounds(sourceStart: "2026-11-01T00:00:00.123455999Z")
        let exact = try ClinicalMeasurementBounds(sourceStart: "2026-11-01T00:00:00.123456000Z")
        #expect(try !before.includes(windowStart: boundary, windowEnd: Self.upper))
        #expect(try exact.includes(windowStart: boundary, windowEnd: Self.upper))
        #expect(try before.includes(windowStart: Self.lower, windowEnd: boundary))
        #expect(try !exact.includes(windowStart: Self.lower, windowEnd: boundary))
    }

    @Test("Missing offsets, partial timestamps and reversed exact intervals fail")
    func invalidBounds() throws {
        #expect(throws: (any Error).self) { try ClinicalMeasurementBounds(sourceStart: "2026-11-01") }
        #expect(throws: (any Error).self) { try ClinicalMeasurementBounds(sourceStart: "2026-11-01T00:00:00") }
        #expect(throws: (any Error).self) {
            try ClinicalMeasurementBounds(sourceStart: "2026-11-01T00:00:00.000000002Z", sourceEnd: "2026-11-01T00:00:00.000000001Z")
        }
        let zero = try ClinicalMeasurementBounds(sourceStart: "2026-11-01T00:00:00Z", sourceEnd: "2026-11-01T00:00:00Z")
        #expect(try zero.includes(windowStart: Self.lower, windowEnd: Self.upper))
        #expect(try !zero.includes(windowStart: Self.lower, windowEnd: Self.lower))
    }
}


extension FHIRMeasurementInstantTests {
    private static var lower: Date {
        get throws { try TroveDateTranscoder().decode("2026-11-01T00:00:00Z") }
    }

    private static var upper: Date {
        get throws { try TroveDateTranscoder().decode("2026-11-01T00:00:01Z") }
    }
}
