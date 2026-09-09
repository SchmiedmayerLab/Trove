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


struct TroveDateTranscoderTests {
    @Test(arguments: [
        (0.0, "2001-01-01T00:00:00.000000Z"),
        (0.123456, "2001-01-01T00:00:00.123456Z"),
        (-0.000001, "2000-12-31T23:59:59.999999Z")
    ])
    func canonicalWireRepresentation(seconds: Double, wire: String) throws {
        let codec = TroveDateTranscoder()
        let date = Date(timeIntervalSinceReferenceDate: seconds)
        #expect(try codec.encode(date) == wire)
        #expect(try codec.decode(wire) == date)
    }

    @Test(arguments: [800_000_000.123456, 800_000_000.999999, 800_000_001.000001])
    func modernDatabaseInstantsRoundTripWithoutBoundaryDrift(seconds: Double) throws {
        let codec = TroveDateTranscoder()
        let date = Date(timeIntervalSinceReferenceDate: seconds)
        #expect(try codec.decode(codec.encode(date)) == date)
    }

    @Test
    func acceptsWholeSecondsAndExplicitOffsets() throws {
        let codec = TroveDateTranscoder()
        #expect(try codec.decode("2001-01-01T00:00:00Z") == Date(timeIntervalSinceReferenceDate: 0))
        #expect(try codec.decode("2000-12-31T16:00:00.123456-08:00") == Date(timeIntervalSinceReferenceDate: 0.123456))
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonfiniteDatesCannotBeEncoded(seconds: Double) {
        #expect(throws: TroveDateTranscoder.DateError.self) {
            try TroveDateTranscoder().encode(Date(timeIntervalSinceReferenceDate: seconds))
        }
    }

    @Test(arguments: ["", "not-a-date", "2001-01-01", String(repeating: "0", count: 41)])
    func malformedDatesAreRejected(value: String) {
        #expect(throws: (any Error).self) { try TroveDateTranscoder().decode(value) }
    }
}
