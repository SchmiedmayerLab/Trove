//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveHealthKit
import HealthKit
import TroveAPIClient


extension TroveStandard: HealthKitConstraint {
    // Collection uses the caller-owned query and atomic journal, not Grove's automatic collectors.
    // Fail closed if a future configuration accidentally activates that separate checkpoint path.
    func handleNewSamples<Sample>(
        _ addedSamples: some Collection<Sample> & Sendable, ofType sampleType: SampleType<Sample>
    ) async throws -> HealthKitAnchorCommitAction? {
        throw EventDeliveryJournal.JournalError.invalidConfiguration
    }

    func handleDeletedObjects<Sample>(
        _ deletedObjects: some Collection<HKDeletedObject> & Sendable,
        ofType sampleType: SampleType<Sample>,
        deletedAfter: Date?
    ) async throws -> HealthKitAnchorCommitAction? {
        throw EventDeliveryJournal.JournalError.invalidConfiguration
    }
}
