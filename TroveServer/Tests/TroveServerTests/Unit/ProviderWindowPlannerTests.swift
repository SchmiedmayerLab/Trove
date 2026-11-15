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
@testable import TroveServer


struct ProviderWindowPlannerTests {
    @Test
    func backfillPreservesUnconsentedGapsAndCompletedRanges() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let first = base..<base.addingTimeInterval(172_800)
        let second = base.addingTimeInterval(259_200)..<base.addingTimeInterval(345_600)
        let completed = [base..<base.addingTimeInterval(43_200)]
        #expect(ProviderWindowPlanner.next(demands: [first, second], completed: completed)
                    == base.addingTimeInterval(43_200)..<base.addingTimeInterval(129_600))
        #expect(ProviderWindowPlanner.next(demands: [first, second], completed: [first]) == second)
        #expect(ProviderWindowPlanner.next(demands: [first, second], completed: [first, second]) == nil)
    }

    @Test
    func overlappingStudyWindowsMergeButDisjointPurposesDoNotExpand() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let one = UUID(), two = UUID()
        let demands: [ProviderDemand] = try [
            .init(consentID: one, profile: "heart-rate", start: base, end: base.addingTimeInterval(100)),
            .init(consentID: two, profile: "heart-rate", start: base.addingTimeInterval(50), end: base.addingTimeInterval(150)),
            .init(consentID: two, profile: "heart-rate", start: base.addingTimeInterval(200), end: base.addingTimeInterval(250))
        ]
        let expected = [base..<base.addingTimeInterval(150), base.addingTimeInterval(200)..<base.addingTimeInterval(250)]
        #expect(ProviderDemandStore.windows(demands) == expected)
    }

    @Test
    func persistedMicrosecondCoverageDoesNotLeaveAnUnrepresentableResidualGap() throws {
        let rawStart = Date(timeIntervalSinceReferenceDate: 800_000_000.1234564)
        let rawEnd = rawStart.addingTimeInterval(60)
        let codec = TroveDateTranscoder()
        let persistedStart = try codec.decode(codec.encode(rawStart))
        let persistedEnd = try codec.decode(codec.encode(rawEnd))
        let demand = try ProviderDemand(consentID: UUID(), profile: "heart-rate", start: rawStart, end: rawEnd)
        #expect(demand.start == persistedStart)
        #expect(demand.end == persistedEnd)
        #expect(ProviderWindowPlanner.next(
            demands: ProviderDemandStore.windows([demand]), completed: [persistedStart..<persistedEnd]
        ) == nil)
    }
}
