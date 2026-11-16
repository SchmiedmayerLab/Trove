//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveSensorKitFHIR
import TroveAPIClient


extension SensorKitAcquisition {
    /// Complete producer custody is authorized across the union of exact-source output scopes.
    /// These profiles do not give a study access to any output it did not select itself.
    static func requiredProfiles(for entry: SensorKitCatalogEntry) throws -> [CollectionObservationProfile] {
        guard let output = entry.implementedOutput else { throw AcquisitionError.invalidBatch }
        let canonicals: [String]
        if let primary = output.observation?.primaryProfile {
            canonicals = [primary] + output.requiredCompanionProfiles
        } else if output.recordingProfiles.contains(SensorKitContract.recordingDocumentProfile) {
            canonicals = [SensorKitContract.recordingDocumentProfile]
        } else { throw AcquisitionError.invalidBatch }
        let profiles = canonicals.compactMap(CollectionObservationProfile.init(rawValue:))
        guard profiles.count == canonicals.count, !profiles.isEmpty else { throw AcquisitionError.invalidBatch }
        return profiles
    }
}
