//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Testing
@testable import Trove
import TroveAPIClient


@Suite
struct HealthDataAdapterStatusTests {
    @Test
    func inactiveAdapterDoesNotHideAnActiveOne() {
        #expect(HealthDataStatus.combining([.notAuthorized, .ready], pending: false, synchronized: false) == .ready)
        #expect(HealthDataStatus.combining([.ready, .notAuthorized], pending: false, synchronized: true) == .syncFinished)
    }

    @Test(arguments: [HealthDataStatus.blocked, .storageFull, .historyUnavailable, .permissionNeeded, .catchUpPending])
    func failureOrIncompleteHistoryIsNotReportedAsSynchronized(_ status: HealthDataStatus) {
        #expect(HealthDataStatus.combining([.ready, status], pending: false, synchronized: true) == status)
    }

    @Test
    func queueAndCapacityRemainObservable() {
        #expect(HealthDataStatus.combining([.ready], pending: true, synchronized: true) == .waiting)
        #expect(HealthDataStatus(error: EventDeliveryJournal.JournalError.capacityExceeded) == .storageFull)
    }
}
