//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

#if canImport(HealthKit)

import Foundation
import Testing
@testable import TroveHealthKit


@Suite(.timeLimit(.minutes(1)))
struct HeartRateCatchUpTests {
    private enum Failure: Error { case expected }

    @Test
    func filteredPagesDoNotPreventReachingLaterAuthorizedData() async throws {
        let source = Pages([
            .init(eventIDs: [], changeCount: 64),
            .init(eventIDs: [UUID()], changeCount: 1),
            .init(eventIDs: [], changeCount: 0)
        ])
        #expect(try await HeartRateAcquisition.catchUp { try await source.next() } == .caughtUp)
        #expect(await source.calls == 3)
    }

    @Test
    func pageBudgetRequiresAnotherPassWithoutSkippingItsNextPage() async throws {
        let source = Pages(Array(repeating: .init(eventIDs: [], changeCount: 64), count: 9) + [.init(eventIDs: [], changeCount: 0)])
        #expect(try await HeartRateAcquisition.catchUp { try await source.next() } == .needsAnotherPass)
        #expect(await source.calls == 8)
        #expect(try await HeartRateAcquisition.catchUp { try await source.next() } == .caughtUp)
        #expect(await source.calls == 10)
    }

    @Test
    func failedPageDoesNotBecomeSuccessfulCatchUp() async {
        await #expect(throws: Failure.self) {
            try await HeartRateAcquisition.catchUp { throw Failure.expected }
        }
    }

    @Test
    func alreadyCancelledPassDoesNotStartAQuery() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await HeartRateAcquisition.catchUp {
                Issue.record("Cancelled catch-up started a query.")
                return .init(eventIDs: [], changeCount: 0)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test
    func cancellationDuringTheLastQueryCannotReportCaughtUp() async {
        let task = Task {
            try await HeartRateAcquisition.catchUp {
                withUnsafeCurrentTask { $0?.cancel() }
                return .init(eventIDs: [], changeCount: 0)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}


extension HeartRateCatchUpTests {
    private actor Pages {
        let pages: [HeartRateAcquisition.Page]
        private(set) var calls = 0

        init(_ pages: [HeartRateAcquisition.Page]) { self.pages = pages }

        func next() throws -> HeartRateAcquisition.Page {
            let page = try #require(pages.indices.contains(calls) ? pages[calls] : nil)
            calls += 1
            return page
        }
    }
}

#endif
