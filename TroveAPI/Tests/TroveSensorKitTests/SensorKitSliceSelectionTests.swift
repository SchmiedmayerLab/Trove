//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPIClient
@testable import TroveSensorKit


struct SensorKitSliceSelectionTests {
    private let profile = CollectionObservationProfile.onWrist
    private let first = UUID()
    private let second = UUID()

    @Test
    func studyWindowBoundariesStartNewSlicesAndGapsStayOutside() throws {
        // Rows 0-3: first study, 4-5: both, 6: nobody, 7-9: second study.
        let authority = rows([[first], [first], [first], [first], [first, second], [first, second], [], [second], [second], [second]])
        let ranges = try SensorKitSliceSelection.ranges(count: 10, retained: [], maximumSlices: 8, authority: authority)
        #expect(ranges == [0..<4, 4..<6, 7..<10])
        #expect(try ranges.map { try SensorKitSliceSelection.sharedAuthority($0, authority: authority)?[profile] } == [
            [first], [first, second], [second]
        ])
        #expect(try SensorKitSliceSelection.sharedAuthority(4..<8, authority: authority) == nil)
        #expect(try SensorKitSliceSelection.sharedAuthority(0..<6, authority: authority)?[profile] == [first])
    }

    @Test
    func laterStudyReusesOnlyRetainedSlicesItCoversCompletely() throws {
        let retained = try [0..<4, 4..<8].map {
            try SensorKitRecordingSlice(rows: $0, sourceRecordID: UUID(), contentDigest: Data(repeating: 7, count: 32))
        }
        // The second study joins later for rows 2-11; rows 8-11 were never uploaded.
        let authority = rows([[first], [first]] + Array(repeating: [first, second], count: 6) + Array(repeating: [second], count: 4))
        let ranges = try SensorKitSliceSelection.ranges(count: 12, retained: retained, maximumSlices: 8, authority: authority)
        #expect(ranges == [0..<4, 4..<8, 8..<12])
        #expect(try SensorKitSliceSelection.sharedAuthority(0..<4, authority: authority)?[profile] == [first])
        #expect(try SensorKitSliceSelection.sharedAuthority(4..<8, authority: authority)?[profile] == [first, second])
        #expect(try SensorKitSliceSelection.sharedAuthority(8..<12, authority: authority)?[profile] == [second])
    }

    @Test
    func retainedSliceWithoutCommonAuthorityIsNotOfferedAgain() throws {
        let retained = try [SensorKitRecordingSlice(rows: 0..<4, sourceRecordID: UUID(), contentDigest: Data(repeating: 7, count: 32))]
        let authority = rows([[first], [first], [second], [second], [second]])
        #expect(try SensorKitSliceSelection.ranges(count: 5, retained: retained, maximumSlices: 8, authority: authority) == [4..<5])
        #expect(throws: EventDeliveryJournal.JournalError.capacityExceeded) {
            try SensorKitSliceSelection.ranges(count: 5, retained: [], maximumSlices: 1, authority: authority)
        }
        let overlapping = try retained + [
            SensorKitRecordingSlice(rows: 3..<5, sourceRecordID: UUID(), contentDigest: Data(repeating: 8, count: 32))
        ]
        #expect(throws: SensorKitAcquisition.AcquisitionError.retryMismatch) {
            try SensorKitSliceSelection.ranges(count: 5, retained: overlapping, maximumSlices: 8, authority: authority)
        }
    }

    @Test
    func companionOutputsSplitSlicesIndependently() throws {
        let recording = CollectionObservationProfile.heartRate
        let authority: (Int) -> SensorKitSliceSelection.Authority? = { row in
            row < 2 ? [profile: [first], recording: [first]] : [profile: [first], recording: [first, second]]
        }
        #expect(try SensorKitSliceSelection.ranges(count: 4, retained: [], maximumSlices: 8, authority: authority) == [0..<2, 2..<4])
        #expect(try SensorKitSliceSelection.sharedAuthority(0..<4, authority: authority) == [profile: [first], recording: [first]])
    }

    private func rows(_ consents: [Set<UUID>]) -> (Int) -> SensorKitSliceSelection.Authority? {
        { consents[$0].isEmpty ? nil : [profile: consents[$0]] }
    }
}
