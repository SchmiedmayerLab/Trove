// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import GroveFHIRContract
import GroveHealthKit


#if canImport(HealthKit)
import HealthKit


#endif


/// The explicitly retained meaning of the timestamps used for collection-window selection.
public typealias CollectionTimeBasis = Components.Schemas.CollectionTimeBasis


extension CollectionTimeBasis {
    /// Derives a source-date basis only from a closed profile and exact generated source definition.
    /// Provider measurements and native measurements continue to use their actual clinical effective time.
    public static func required(profile: String, sourceTypeIdentifier: String?) -> Self {
        guard let sourceTypeIdentifier,
              let source = FHIRMeasurementCatalog.healthKitSource(identifier: sourceTypeIdentifier) else {
            return .measurementTime
        }
        if source.profiles.contains(Profile.healthkitClinicalRecordDocument),
           profile == Profile.healthkitClinicalRecordDocument.value?.url.absoluteString {
            return .clinicalRecordDownload
        }
        if sourceTypeIdentifier == HKDocumentType(.CDA).identifier,
           source.profiles.contains(Profile.healthkitRecordingDocument),
           profile == Profile.healthkitRecordingDocument.value?.url.absoluteString {
            return .cdaSourceDocumentPeriod
        }
        return .measurementTime
    }

    /// Existing omitted values retain measurement semantics; documents always need an explicit accepted basis.
    public static func accepts(_ value: Self?, profile: String, sourceTypeIdentifier: String?) -> Bool {
        (value ?? .measurementTime) == required(profile: profile, sourceTypeIdentifier: sourceTypeIdentifier)
    }
}
