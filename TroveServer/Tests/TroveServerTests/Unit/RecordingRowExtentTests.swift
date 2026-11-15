//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import GroveFHIRContract
import Testing
@testable import TroveServer


struct RecordingRowExtentTests {
    private static let pedometerHeader = "start,end,steps,distance,floorsUp,floorsDown,currentPace,currentCadence,avgActivePace,device\n"

    @Test
    func pointRowsAreSelectedHalfOpenAndOnlyTogether() throws {
        let rows = try extent("timestamp,value,confidence,device\n10,72.00000000000001,3,Watch\n19.999999999,73,3,Watch\n", format: .heartRateSamples)
        #expect(try rows.isSelected(windowStart: date(10), windowEnd: date(20)))
        #expect(try rows.isSelected(windowStart: date(10), windowEnd: nil))
        #expect(try !rows.isSelected(windowStart: date(10.001), windowEnd: date(20)))
        #expect(try !rows.isSelected(windowStart: date(10), windowEnd: date(19)))
        let boundary = try extent("timestamp,value,confidence,device\n10,72,3,Watch\n20,73,3,Watch\n", format: .heartRateSamples)
        #expect(try !boundary.isSelected(windowStart: date(10), windowEnd: date(20)))
    }

    @Test
    func enclosingPeriodDoesNotAuthorizeARowOutsideTheWindow() throws {
        // The window overlaps the batch envelope 10...30 without selecting its last row.
        let rows = try extent("timestamp,value,confidence,device\n10,72,3,Watch\n30,74,3,Watch\n", format: .heartRateSamples)
        #expect(try !rows.isSelected(windowStart: date(5), windowEnd: date(25)))
        #expect(try !rows.isSelected(windowStart: date(15), windowEnd: date(40)))
        #expect(try rows.isSelected(windowStart: date(5), windowEnd: date(40)))
    }

    @Test
    func nativeIntervalRowsAreSelectedWholeWhenTheyOverlap() throws {
        let rows = try extent(Self.pedometerHeader + "9,11,5,,,,,,,Watch\n19,21,5,,,,,,,Watch\n", format: .pedometerSamples)
        #expect(try rows.isSelected(windowStart: date(10), windowEnd: date(20)))
        #expect(try !rows.isSelected(windowStart: date(11), windowEnd: date(20)))
        #expect(try !rows.isSelected(windowStart: date(10), windowEnd: date(19)))
        let instant = try extent(Self.pedometerHeader + "20,20,5,,,,,,,Watch\n", format: .pedometerSamples)
        #expect(try !instant.isSelected(windowStart: date(10), windowEnd: date(20)))
        #expect(try instant.isSelected(windowStart: date(20), windowEnd: date(21)))
    }

    @Test
    func onlyQueryBatchesCarryRowsAndAnEmptyBatchIsNeverSelected() throws {
        #expect(try !RecordingRowExtent().isSelected(windowStart: date(0), windowEnd: nil))
        #expect(!RecordingRowExtent.applies(to: .wristTemperatureSamples))
        #expect(!RecordingRowExtent.applies(to: .beatIntervalSeries))
        #expect(!RecordingRowExtent.applies(to: .locationTrackSamples))
        #expect(RecordingRowExtent.applies(to: .triaxialAccelerationSamples))
    }

    @Test
    func rowEvidenceSurvivesCustodyPersistenceAndIsAbsentFromEarlierEvidence() throws {
        var bounds = RecordingRouteBounds()
        let reader = try RecordingCSVReader(
            Data("timestamp,value,confidence,device\n10,72,3,Watch\n20.5,73,3,Watch\n".utf8), format: .heartRateSamples
        )
        for row in reader.rows { try bounds.include(row, format: .heartRateSamples) }
        let verified = RecordingContentVerification(bounds: bounds, attachmentSHA1: Data(Insecure.SHA1.hash(data: Data())))
        let restored = try RecordingContentVerification(restoring: verified.serialized)
        #expect(restored.bounds.rows == bounds.rows)
        #expect(try restored.bounds.rows?.isSelected(windowStart: date(10), windowEnd: date(20.6)) == true)
        #expect(try restored.bounds.rows?.isSelected(windowStart: date(10), windowEnd: date(20.5)) == false)
        let earlier = #"{"attachmentSHA1":"\#(verified.attachmentSHA1.base64EncodedString())","first":0,"last":1}"#
        #expect(try RecordingContentVerification(restoring: earlier).bounds.rows == nil)
    }

    private func extent(_ csv: String, format: RegisteredRecordingFormat) throws -> RecordingRowExtent {
        var rows = RecordingRowExtent()
        for row in try RecordingCSVReader(Data(csv.utf8), format: format).rows { try rows.include(row, format: format) }
        return rows
    }

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }
}
