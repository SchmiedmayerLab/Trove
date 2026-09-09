//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import TroveServer


struct ConsentCollectionTimelineTests {
    @Test(arguments: [0.0, 5.0])
    func nextAdoptionClosesThePreviousWindowIncludingEqualTimestamps(offset: Double) throws {
        let first = Self.acceptance(revision: 1, time: 100)
        let second = Self.acceptance(revision: 3, time: 100 + offset)
        let windows = try ConsentCollectionTimeline.windows(
            [first, second], currentRevision: 3, stateVersion: 4, asOf: Date(timeIntervalSince1970: 200)
        )
        #expect(windows.count == 2)
        #expect(windows[0].acceptance.consentID == first.consentID)
        #expect(windows[0].end == second.acceptedAt)
        #expect(windows[1].end == nil)
    }

    @Test
    func noConsentHasNoCollectionWindow() throws {
        #expect(try ConsentCollectionTimeline.windows([], currentRevision: 3, stateVersion: 1, asOf: Date()).isEmpty)
    }

    @Test(arguments: ["backward-time", "future-time", "nonfinite-time", "backward-revision", "backward-version", "duplicate-id"])
    func inconsistentHistoryFailsAsAWhole(failure: String) {
        let first = Self.acceptance(revision: 1, time: 100)
        let second = ConsentCollectionTimeline.Acceptance(
            consentID: failure == "duplicate-id" ? first.consentID : UUID(),
            publicationID: UUID(),
            revision: failure == "backward-revision" ? 1 : 2,
            stateVersion: failure == "backward-version" ? 2 : 3,
            acceptedAt: Date(timeIntervalSince1970: failure == "nonfinite-time" ? .nan : failure == "backward-time" ? 99 : 101)
        )
        #expect(throws: ServerError.self) {
            try ConsentCollectionTimeline.windows(
                [first, second],
                currentRevision: second.revision,
                stateVersion: 3,
                asOf: Date(timeIntervalSince1970: failure == "future-time" ? 100 : 200)
            )
        }
    }

    @Test(arguments: [(1, Int64(3)), (2, 2)])
    func enrollmentMustMatchItsLatestAcceptance(revision: Int, version: Int64) {
        #expect(throws: ServerError.self) {
            try ConsentCollectionTimeline.windows(
                [Self.acceptance(revision: 2, time: 100)], currentRevision: revision, stateVersion: version, asOf: Date()
            )
        }
    }

    @Test
    func historyLimitNeverSilentlyTruncatesEarlierAuthority() throws {
        var history = (1...1024).map { Self.acceptance(revision: $0, time: Double($0)) }
        #expect(try ConsentCollectionTimeline.windows(history, currentRevision: 1024, stateVersion: 1025, asOf: Date()).count == 1024)
        history.append(Self.acceptance(revision: 1025, time: 1025))
        #expect(throws: ServerError.self) {
            try ConsentCollectionTimeline.windows(history, currentRevision: 1025, stateVersion: 1026, asOf: Date())
        }
    }
}


extension ConsentCollectionTimelineTests {
    private static func acceptance(revision: Int, time: Double) -> ConsentCollectionTimeline.Acceptance {
        .init(
            consentID: UUID(),
            publicationID: UUID(),
            revision: revision,
            stateVersion: Int64(revision + 1),
            acceptedAt: Date(timeIntervalSince1970: time)
        )
    }
}
