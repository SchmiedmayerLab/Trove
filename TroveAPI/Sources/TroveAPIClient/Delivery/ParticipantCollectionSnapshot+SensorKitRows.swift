//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPITypes


extension ParticipantCollectionSnapshot {
    /// Selects one native row independently of its enclosing recording's aggregate temporal shape.
    /// Point rows use half-open membership; a genuine native interval row retains its whole overlapping interval.
    public func sensorKitRowConsentIDs(
        profile: CollectionObservationProfile, sourceTypeIdentifier: String, start: Date, end: Date?
    ) throws -> [UUID] {
        guard SensorKitCollectionCapabilities.outputs(for: sourceTypeIdentifier).contains(where: { $0.profile == profile.rawValue }),
              start.timeIntervalSinceReferenceDate.isFinite,
              end.map({ $0.timeIntervalSinceReferenceDate.isFinite && $0 >= start }) ?? true else {
            throw CollectionError.invalidPlan
        }
        return try plans.compactMap { plan in
            guard let window = plan.windows.reversed().first(where: { window in
                window.requirements.contains { requirement in
                    requirement.sourceKind == .participantApp && requirement.profile == profile.rawValue
                        && requirement.sourceTypeIdentifier == sourceTypeIdentifier
                        && CollectionMeasurementSelection.includes(
                            sampleStart: start, sampleEnd: end, windowStart: requirement.start, windowEnd: requirement.end
                        )
                }
            }) else { return nil }
            guard let consentID = UUID(uuidString: window.consentId) else { throw CollectionError.invalidPlan }
            return consentID
        }
    }
}
