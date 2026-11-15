// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

#if canImport(HealthKit)

import Foundation
import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit
import TroveAPIClient


extension HealthKitAcquisition {
    /// One ECG per page: a 30-second recording carries about 15,000 voltages, which convert inline into its waveform.
    /// Voltages and correlated symptoms are read only after the ECG's interval has an accepted consent.
    static func queryElectrocardiograms(
        _ healthKit: GroveHealthKit.HealthKit, anchor: inout QueryAnchor, predicate: NSPredicate
    ) async throws -> Delta {
        let changes = try await healthKit.query(.electrocardiogram, timeRange: .ever, anchor: &anchor, limit: 1, predicate: predicate)
        return Delta(
            added: changes.added,
            deletedIDs: changes.deleted.map(\.uuid),
            nextAnchor: anchor,
            readElectrocardiogram: { ecg in
                let voltages = try await ecg.rawVoltageMeasurements(from: healthKit.healthStore)
                return .electrocardiogram(ecg, voltages: voltages, symptoms: try await symptoms(of: ecg, healthKit: healthKit))
            }
        )
    }

    /// The symptoms HealthKit associates with `ecg`. The waveform names each one by identity; each remains its own
    /// record, collected only through its own consented stream. Reading never prompts for permission.
    private static func symptoms(of ecg: HKElectrocardiogram, healthKit: GroveHealthKit.HealthKit) async throws -> [HKCategorySample] {
        guard ecg.symptomsStatus == .present else {
            return []
        }
        // SAFETY: the predicate does not use a block, so sharing it with the query is safe.
        nonisolated(unsafe) let predicate = HKQuery.predicateForObjectsAssociated(electrocardiogram: ecg)
        var symptoms: [HKCategorySample] = []
        for type in HKElectrocardiogram.correlatedSymptomTypes {
            symptoms += try await healthKit.query(type, timeRange: .ever, predicate: predicate)
        }
        return symptoms
    }

    /// HealthKit read types a stream needs. An ECG with reported symptoms cannot be converted without reading them.
    public static func readTypes(for stream: HealthKitQueryDefinition.Stream) throws -> [HKObjectType] {
        let primary = try sampleType(for: stream)
        guard stream.profile == .electrocardiogram else {
            return [primary]
        }
        return [primary] + HKElectrocardiogram.correlatedSymptomTypes.map(\.hkSampleType)
    }
}

#endif
