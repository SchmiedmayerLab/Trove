// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import GroveFHIRContract
import TroveAPIServer
import TroveAPITypes


/// Receiver support and implemented native streams, not a blanket publication of the guide inventory.
enum NativeCollectionCapabilities {
    static func values() throws -> [Components.Schemas.CollectionCapability] {
        let healthKit = try CollectionObservationProfile.allCases.flatMap { profile in
            try profile.nativeSources.map { source in
                try capability(profile: profile, source: source)
            }
        }
        let sensors = try SensorKitCollectionCapabilities.sources.flatMap { source in
            try SensorKitCollectionCapabilities.outputs(for: source.sourceToken).map { output in
                try sensorCapability(sourceTypeIdentifier: source.sourceToken, output: output)
            }
        }
        return healthKit + sensors
    }

    private static func sensorCapability(
        sourceTypeIdentifier: String, output: SensorKitCollectionCapabilities.Output
    ) throws -> Components.Schemas.CollectionCapability {
        let english = try CollectionScopePresentation.displayName(output.profile, german: false, sourceTypeIdentifier: sourceTypeIdentifier)
        let german = try CollectionScopePresentation.displayName(output.profile, german: true, sourceTypeIdentifier: sourceTypeIdentifier)
        return .init(
            profile: output.profile,
            repositoryKind: .sensorkit,
            sourceTypeIdentifier: sourceTypeIdentifier,
            displayNameEnglish: english,
            displayNameGerman: german,
            effectiveTime: output.effective == .period ? .interval : .pointOrInterval,
            supportsWorkoutRoutes: false,
            isOriginalRecording: output.isRecording,
            requiredCompanionProfiles: output.requiredCompanionProfiles
        )
    }

    private static func capability(
        profile: CollectionObservationProfile, source: HealthKitSourceDefinition
    ) throws -> Components.Schemas.CollectionCapability {
        let temporal: Components.Schemas.CollectionCapability.EffectiveTimePayload
        if profile == .healthKitRecording || profile == .clinicalDocument || profile == .electrocardiogram {
            temporal = .interval
        } else if let measurement = profile.measurement {
            temporal = switch measurement.effective {
            case .dateTime: .point
            case .period: .interval
            case .dateTimeOrPeriod: .pointOrInterval
            }
        } else {
            throw ServerError.unexpectedError
        }
        let english = try CollectionScopePresentation.displayName(profile.rawValue, german: false, sourceTypeIdentifier: source.sourceTypeIdentifier)
        let german = try CollectionScopePresentation.displayName(profile.rawValue, german: true, sourceTypeIdentifier: source.sourceTypeIdentifier)
        return .init(
            profile: profile.rawValue,
            repositoryKind: .healthkit,
            sourceTypeIdentifier: source.sourceTypeIdentifier,
            displayNameEnglish: english,
            displayNameGerman: german,
            effectiveTime: temporal,
            supportsWorkoutRoutes: profile == .workout,
            isOriginalRecording: profile == .healthKitRecording || profile == .clinicalDocument,
            timeBasis: CollectionTimeBasis.required(profile: profile.rawValue, sourceTypeIdentifier: source.sourceTypeIdentifier)
        )
    }
}


extension Controller {
    func getCollectionCapabilities(
        _ input: Operations.GetCollectionCapabilities.Input
    ) async throws -> Operations.GetCollectionCapabilities.Output {
        guard AuthContext.current != nil else { throw ServerError.missingToken }
        return .ok(.init(body: .json(try NativeCollectionCapabilities.values())))
    }
}
