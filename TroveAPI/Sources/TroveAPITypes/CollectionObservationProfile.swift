//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveHealthKit
import GroveProviderFHIR
import GroveSensorKitFHIR
import ModelsR4


#if canImport(HealthKit)
import HealthKit


#endif


/// Closed receiver capabilities selected from implemented producer shapes in Grove's pinned contracts.
public struct CollectionObservationProfile: RawRepresentable, CaseIterable, Hashable, Codable, Sendable {
    public static let maximumRequirements = 512

    public static let heartRate = Self(knownProfile: Profile.groveMobileHeartRate)
    public static let bodyWeight = Self(knownProfile: Profile.groveMobileBodyWeight)
    public static let sleepStage = Self(knownProfile: Profile.groveMobileSleepStage)
    public static let workout = Self(knownProfile: Profile.groveMobileWorkout)
    public static let bloodPressure = Self(knownProfile: Profile.groveMobileBloodPressure)
    public static let stateOfMind = Self(knownProfile: Profile.healthkitStateOfMind)
    public static let gad7 = Self(knownProfile: Profile.healthkitGad7Assessment)
    public static let phq9 = Self(knownProfile: Profile.healthkitPhq9Assessment)
    public static let clinicalDocument = Self(knownProfile: Profile.healthkitClinicalRecordDocument)
    public static let food = Self(knownProfile: Profile.healthkitFoodCorrelation)
    public static let healthKitRecording = Self(knownProfile: Profile.healthkitRecordingDocument)
    public static let audiogram = Self(knownProfile: Profile.healthkitAudiogramPanel)
    public static let onWrist = Self(knownProfile: Profile.sensorkitOnWristObservation)

    /// Native quantities and categories with implemented scalar/coded conversion and declared components.
    public static let quantitySources = scalarSources(prefix: "HKQuantityTypeIdentifier")
    public static let categorySources = scalarSources(prefix: "HKCategoryTypeIdentifier")

    public static let allCases: [Self] = {
        var seen: Set<String> = []
        let scalars = (quantitySources + categorySources).compactMap { source -> Self? in
            guard let id = source.measurementIDs.first,
                  let profile = FHIRMeasurementCatalog.measurement(id: id)?.profile.value?.url.absoluteString else {
                return nil
            }
            return Self(profile)
        }
        let providers = ProviderCapabilities.Provider.allCases.flatMap { provider in
            ProviderCapabilities.sources(for: provider)
                .filter { $0.conversionSupport == .structured || $0.conversionSupport == .nativeRecording }
                .flatMap(\.outputProfiles)
        }
        .map { Self(knownProfile: $0) }
        let structured: [Self] = [
            .sleepStage, .workout, .bloodPressure, .stateOfMind, .gad7, .phq9, .audiogram, .healthKitRecording, .clinicalDocument, .food, .onWrist
        ]
        let sensors = SensorKitCollectionCapabilities.sources.flatMap { source in
            SensorKitCollectionCapabilities.outputs(for: source.sourceToken).map { Self($0.profile) }
        }
        return (scalars + structured + providers + sensors).filter { seen.insert($0.rawValue).inserted }
    }()

    public let rawValue: String

    /// Several native streams may share one semantic profile; the source token remains part of collection authority.
    public var nativeSources: [HealthKitSourceDefinition] {
        if self == .clinicalDocument {
            return FHIRMeasurementCatalog.healthKitSources.filter { $0.profiles.contains(Profile.healthkitClinicalRecordDocument) }
        }
        if self == .healthKitRecording {
            let identifiers = [SampleType.heartbeatSeries.hkSampleType.identifier, HKDocumentType(.CDA).identifier]
            return FHIRMeasurementCatalog.healthKitSources.filter {
                identifiers.contains($0.sourceTypeIdentifier) && $0.profiles.contains(Profile.healthkitRecordingDocument)
            }
        }
        let sources = Self.quantitySources + Self.categorySources
        let matches = sources.filter { source in
            source.measurementIDs.first.flatMap(FHIRMeasurementCatalog.measurement(id:))?.profile.value?.url.absoluteString == rawValue
        }
        if !matches.isEmpty {
            return matches
        }
        guard [.bloodPressure, .stateOfMind, .gad7, .phq9, .audiogram, .workout, .food].contains(self), let measurement else {
            return []
        }
        return FHIRMeasurementCatalog.healthKitSources.filter { $0.measurementIDs.first == measurement.id }
    }

    /// SensorKit capabilities remain qualified by the exact source token even when an output profile is shared.
    public var sensorKitSources: [SensorKitOutputDefinition] {
        SensorKitCollectionCapabilities.sources(for: rawValue)
    }

    public var quantitySource: HealthKitSourceDefinition? {
        nativeSources.first { $0.sourceTypeIdentifier.hasPrefix("HKQuantityTypeIdentifier") }
    }

    public var categorySource: HealthKitSourceDefinition? {
        nativeSources.first { $0.sourceTypeIdentifier.hasPrefix("HKCategoryTypeIdentifier") }
    }

    public var measurement: FHIRMeasurementDefinition? {
        FHIRMeasurementCatalog.measurements.first { $0.profile.value?.url.absoluteString == rawValue }
    }

    /// Exact source token for an implemented native stream; raw recordings may later share one profile.
    public var nativeSourceTypeIdentifier: String? {
        let identifiers = nativeSources.map(\.sourceTypeIdentifier) + sensorKitSources.map(\.sourceToken)
        return identifiers.count == 1 ? identifiers.first : nil
    }

    /// Older retained semantic scopes remain readable; new source families must name their exact stream.
    public var permitsLegacyUnqualifiedSource: Bool {
        [.heartRate, .bodyWeight, .sleepStage, .workout].contains(self)
    }

    /// Whether the contract requires a whole period. Dual-shape query versions handle both forms explicitly.
    public var isInterval: Bool {
        self == .sleepStage || self == .workout || self == .healthKitRecording || self == .clinicalDocument || measurement?.effective == .period
            || (!sensorKitSources.isEmpty && sensorKitSources.allSatisfy { source in
                SensorKitCollectionCapabilities.outputs(for: source.sourceToken)
                    .filter { $0.profile == rawValue }
                    .allSatisfy { $0.effective == .period }
            })
    }

    private init(_ rawValue: String) { self.rawValue = rawValue }

    private init(knownProfile: FHIRPrimitive<Canonical>) {
        guard let canonical = knownProfile.value?.url.absoluteString else {
            preconditionFailure("A generated collection profile must have a canonical URI")
        }
        rawValue = canonical
    }

    public init?(rawValue: String) {
        guard Self.allCases.contains(where: { $0.rawValue == rawValue }) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported collection capability")
        }
        self = value
    }

    private static func scalarSources(prefix: String) -> [HealthKitSourceDefinition] {
        FHIRMeasurementCatalog.healthKitSources.filter { source in
            guard source.guideStatus == .supported, source.sourceTypeIdentifier.hasPrefix(prefix),
                  source.measurementIDs.count == 1, let id = source.measurementIDs.first,
                  let definition = FHIRMeasurementCatalog.measurement(id: id) else { return false }
            return (definition.valueShape == .quantity || definition.valueShape == .coded)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Reuse Grove's localized HealthKit type names, with explicit language selection for retained consent.
    public func localizedNativeTitle(language: String, sourceTypeIdentifier: String? = nil) -> String? {
        let language = Locale.Language(identifier: language)
        let source = sourceTypeIdentifier.flatMap { identifier in nativeSources.first { $0.sourceTypeIdentifier == identifier } }
            ?? (nativeSources.count == 1 ? nativeSources.first : nil)
        if let source, source.sourceTypeIdentifier.hasPrefix("HKQuantityTypeIdentifier") {
            return SampleType<HKQuantitySample>(HKQuantityTypeIdentifier(rawValue: source.sourceTypeIdentifier))?.localizedTitle(in: language)
        }
        if let source, source.sourceTypeIdentifier.hasPrefix("HKCategoryTypeIdentifier") {
            return SampleType<HKCategorySample>(HKCategoryTypeIdentifier(rawValue: source.sourceTypeIdentifier))?.localizedTitle(in: language)
        }
        if let title = localizedDocumentTitle(language: language, source: source) {
            return title
        }
        return localizedStructuredTitle(language: language)
    }

    private func localizedStructuredTitle(language: Locale.Language) -> String? {
        switch self {
        case .food: SampleType.food.localizedTitle(in: language)
        case .bloodPressure: SampleType.bloodPressure.localizedTitle(in: language)
        case .stateOfMind: SampleType.stateOfMind.localizedTitle(in: language)
        case .gad7: SampleType.gad7.localizedTitle(in: language)
        case .phq9: SampleType.phq9.localizedTitle(in: language)
        case .audiogram: SampleType.audiogram.localizedTitle(in: language)
        case .healthKitRecording: SampleType.heartbeatSeries.localizedTitle(in: language)
        default: nil
        }
    }

    private func localizedDocumentTitle(language: Locale.Language, source: HealthKitSourceDefinition?) -> String? {
        #if !os(watchOS)
        if let source, self == .clinicalDocument {
            return SampleType<HKClinicalRecord>(HKClinicalTypeIdentifier(rawValue: source.sourceTypeIdentifier))?.localizedTitle(in: language)
        }
        #endif
        if source?.sourceTypeIdentifier == HKDocumentType(.CDA).identifier {
            return language.languageCode?.identifier == "de" ? "CDA-Dokumente" : "CDA documents"
        }
        return nil
    }

    public func permitsNativeSource(_ identifier: String?) -> Bool {
        if let identifier {
            return nativeSources.contains { $0.sourceTypeIdentifier == identifier }
                || sensorKitSources.contains { $0.sourceToken == identifier }
        }
        return permitsLegacyUnqualifiedSource
    }

    public func matchesSource(expected: String?, actual: String?, requiresWorkoutRoute: Bool = false) -> Bool {
        guard let expected else {
            return permitsLegacyUnqualifiedSource
        }
        if requiresWorkoutRoute, self == .workout,
           actual == SampleType.workoutRoute.hkSampleType.identifier, expected == nativeSourceTypeIdentifier {
            return true
        }
        return expected == actual
    }

    /// Receiver and consent checks preserve the actual effective datatype, including dual-shape profiles.
    public func permitsEffectiveTime(hasEnd: Bool) -> Bool {
        if self == .healthKitRecording || self == .clinicalDocument {
            return hasEnd
        }
        let sensors = sensorKitSources
        if !sensors.isEmpty {
            return sensors.contains { source in
                SensorKitCollectionCapabilities.outputs(for: source.sourceToken).contains { output in
                    output.profile == rawValue && (output.effective == .dateTimeOrPeriod || hasEnd)
                }
            }
        }
        switch measurement?.effective {
        case .dateTime: return !hasEnd
        case .period: return hasEnd
        case .dateTimeOrPeriod: return true
        case nil: return false
        }
    }
}
