//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveFHIRContract
import ModelsR4
import TroveAPITypes


/// A HealthKit ECG is one source record: its waveform and the average heart rate derived from it are selected together.
/// Correlated symptoms are separate source records that the waveform names by output identity; naming one grants nothing.
/// When a present symptoms status could not read them, the waveform carries one member that states only the data-absent
/// reason `unknown`; it names nothing and grants nothing. Complete FHIR validation precedes this receiver capability check.
enum FHIRHealthKitECGBoundary {
    static let waveformProfiles = Set(
        [Profile.groveSensorEcgObservation, Profile.healthkitEcgObservation].compactMap { $0.value?.url.absoluteString }
    )
    static let averageHeartRateProfile = Profile.healthkitEcgAverageHeartRateObservation.value?.url.absoluteString ?? ""
    static let leadSystem = "urn:iso:std:iso:11073:10101"
    static let leadCode = "131329"
    static let classificationSystem = Canonicals.root + "/healthkit/CodeSystem/healthkit-ecg-classification"
    static let algorithmVersionSystem = Canonicals.root + "/healthkit/CodeSystem/healthkit-ecg-algorithm-version"
    static let dataAbsentReasonURL = Canonicals.dataAbsentReason.value?.url.absoluteString ?? ""
    static let unreadableSymptomsCode = "unknown"

    /// The waveform: one lead of millivolt samples, one classification, at most one algorithm version, and symptoms
    /// named only by identity or stated unreadable. Its effective Period is checked with the other temporal facts.
    static func validateWaveform(_ observation: Observation) throws {
        let profiles = (observation.meta?.profile ?? []).compactMap { $0.value?.url.absoluteString }
        guard profiles.count == waveformProfiles.count, Set(profiles) == waveformProfiles,
              observation.value == nil, observation.dataAbsentReason == nil,
              let components = observation.component, components.count == 1, let lead = components.first,
              lead.dataAbsentReason == nil, lead.extension?.isEmpty != false,
              try coding(lead.code, system: leadSystem) == leadCode,
              case .sampledData(let data)? = lead.value, data.dimensions.value?.integer == 1, data.origin.code?.value?.string == "mV",
              let interpretations = observation.interpretation, interpretations.count == 1, let interpretation = interpretations.first else {
            throw FHIRValidationClient.invalid
        }
        try FHIRSensorKitObservationProjection.waveform(data)
        _ = try coding(interpretation, system: classificationSystem)
        if let method = observation.method {
            _ = try coding(method, system: algorithmVersionSystem)
        }
        try symptomMembers(observation)
    }

    /// Symptoms named only by identity, each once, or, for a present symptoms status whose symptoms could not be read,
    /// exactly one member that carries nothing but the data-absent reason `unknown`.
    static func symptomMembers(_ observation: Observation) throws {
        let members = observation.hasMember ?? []
        guard members.contains(where: { $0.extension?.isEmpty == false }) else {
            try FHIRFoodProjection.independentMembers(members)
            return
        }
        guard members.count == 1, let member = members.first,
              member.id == nil, member.reference == nil, member.type == nil, member.identifier == nil, member.display == nil,
              let reasons = member.extension, reasons.count == 1, let reason = reasons.first,
              reason.id == nil, reason.extension?.isEmpty != false,
              reason.url.value?.url.absoluteString == dataAbsentReasonURL,
              case .code(let code)? = reason.value, code.value?.string == unreadableSymptomsCode,
              symptomsStatus(observation) == "present" else {
            throw FHIRValidationClient.invalid
        }
    }

    private static func symptomsStatus(_ observation: Observation) -> String? {
        let url = Canonicals.healthKitECGSymptomsStatusExtension.value?.url.absoluteString
        let statuses = (observation.extension ?? []).filter { $0.url.value?.url.absoluteString == url }
        guard statuses.count == 1, case .code(let code)? = statuses.first?.value else {
            return nil
        }
        return code.value?.string
    }

    /// The waveform's symptoms status and source period. Full validation establishes their values; the location walk
    /// admits only the timezone on the period's instants.
    static func accepts(_ value: Extension, resourceType: String) -> Bool {
        guard resourceType == "Observation", value.extension?.isEmpty != false else {
            return false
        }
        let url = value.url.value?.url.absoluteString
        return switch value.value {
        case .code: url == Canonicals.healthKitECGSymptomsStatusExtension.value?.url.absoluteString
        case .period: url == Canonicals.healthKitECGSourcePeriodExtension.value?.url.absoluteString
        default: false
        }
    }

    /// Event shape: one waveform and at most one average heart rate, derived from it over exactly its Period.
    static func validate(resources: [String: ResourceProxy]) throws {
        let observations = resources.compactMap { address, resource -> (String, Observation)? in
            if case .observation(let observation) = resource { (address, observation) } else { nil }
        }
        let waveforms = observations.filter { isWaveform($0.1) }
        let averages = observations.filter { profiles($0.1).contains(averageHeartRateProfile) }
        guard !waveforms.isEmpty || !averages.isEmpty else {
            return
        }
        guard waveforms.count == 1, averages.count <= 1, waveforms.count + averages.count == observations.count,
              let (address, waveform) = waveforms.first else { throw FHIRValidationClient.invalid }
        for (_, average) in averages {
            guard let origins = average.derivedFrom, origins.count == 1, origins.first?.reference?.value?.string == address,
                  average.hasMember?.isEmpty != false, average.component?.isEmpty != false,
                  case .period(let period)? = average.effective, case .period(let source)? = waveform.effective,
                  try bounds(period) == bounds(source) else { throw FHIRValidationClient.invalid }
        }
    }

    /// The average heart rate is collected under the waveform's requirement and interval.
    static func collectionOutputs(_ outputs: [ClinicalGrantStore.Output]) throws -> [ClinicalGrantStore.Output] {
        let waveforms = outputs.filter { $0.profile == CollectionObservationProfile.electrocardiogram.rawValue }
        guard let waveform = waveforms.first else {
            return outputs
        }
        guard waveforms.count == 1, outputs.count <= 2, outputs.allSatisfy({
            $0.sourceTypeIdentifier == waveform.sourceTypeIdentifier && $0.measurementBounds == waveform.measurementBounds
                && ($0.profile == waveform.profile || $0.profile == CollectionObservationProfile.heartRate.rawValue)
        }) else { throw FHIRValidationClient.invalid }
        return outputs.map {
            .init(
                fullURL: $0.fullURL,
                profile: waveform.profile,
                measurementBounds: waveform.measurementBounds,
                sourceTypeIdentifier: waveform.sourceTypeIdentifier
            )
        }
    }

    static func requireCompleteSelection(_ selected: Set<String>, outputs: [ClinicalGrantStore.Output]) throws {
        guard outputs.contains(where: { $0.profile == CollectionObservationProfile.electrocardiogram.rawValue }) else {
            return
        }
        guard selected == Set(outputs.map(\.fullURL)) else {
            throw ServerError.forbidden("An ECG selection must include its waveform and derived average heart rate")
        }
    }

    private static func isWaveform(_ observation: Observation) -> Bool {
        !waveformProfiles.isDisjoint(with: profiles(observation))
    }

    private static func profiles(_ observation: Observation) -> Set<String> {
        Set((observation.meta?.profile ?? []).compactMap { $0.value?.url.absoluteString })
    }

    private static func bounds(_ period: Period) throws -> ClinicalMeasurementBounds {
        guard let start = period.start?.value, let end = period.end?.value else { throw FHIRValidationClient.invalid }
        return try .init(start: FHIRMeasurementInstant.exact(start), end: FHIRMeasurementInstant.exact(end))
    }

    private static func coding(_ concept: CodeableConcept, system: String) throws -> String {
        guard let codings = concept.coding, codings.count == 1, let coding = codings.first,
              coding.system?.value?.url.absoluteString == system, let code = coding.code?.value?.string, !code.isEmpty else {
            throw FHIRValidationClient.invalid
        }
        return code
    }
}
