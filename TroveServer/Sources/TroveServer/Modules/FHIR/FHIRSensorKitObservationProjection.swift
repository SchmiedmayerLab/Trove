//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveSensorKitFHIR
import ModelsR4
import TroveAPITypes


/// Searchable SensorKit facts after complete IG validation. The source-bound roster
/// governs receiver admission; immutable bytes retain all components and their precision.
struct FHIRSensorKitObservationProjection {
    let measurementBounds: ClinicalMeasurementBounds
    let value: ClinicalOutputValue
    let codeSystem: String
    let code: String

    static func project(
        _ observation: Observation, capability: CollectionObservationProfile, quantityText: String?
    ) throws -> Self? {
        let sources = capability.sensorKitSources
        guard !sources.isEmpty else {
            return nil
        }
        let evidence = try FHIRSourceTypeEvidence.extract(observation.extension ?? [])
        let matches = sources.filter { $0.sourceToken == evidence?.identifier }
        guard evidence?.repository == .sensorKit, matches.count == 1,
              let definition = matches.first?.observation else { throw FHIRValidationClient.invalid }
        let profiles = (observation.meta?.profile ?? []).compactMap { $0.value?.url.absoluteString }
        guard profiles.count == definition.profiles.count, Set(profiles) == Set(definition.profiles),
              observation.hasMember?.isEmpty != false, observation.dataAbsentReason == nil else { throw FHIRValidationClient.invalid }
        let bounds = try effective(observation, definition: definition)
        try focus(observation.focus ?? [], contract: definition.contract)
        try components(observation.component ?? [], bounds: bounds, contract: definition.contract)
        let code = try primaryCoding(observation.code)
        return try Self(
            measurementBounds: bounds,
            value: value(observation, shape: definition.valueShape, quantityText: quantityText),
            codeSystem: code.system,
            code: code.code
        )
    }

    private static func effective(
        _ observation: Observation, definition: SensorKitOutputDefinition.Observation
    ) throws -> ClinicalMeasurementBounds {
        switch observation.effective {
        case .dateTime(let primitive) where definition.effective == .dateTimeOrPeriod:
            guard let value = primitive.value else { throw FHIRValidationClient.invalid }
            return try .init(start: FHIRMeasurementInstant.exact(value))
        case .period(let period):
            return try bounds(period)
        default: throw FHIRValidationClient.invalid
        }
    }

    private static func bounds(_ period: Period) throws -> ClinicalMeasurementBounds {
        guard let start = period.start?.value, let end = period.end?.value else { throw FHIRValidationClient.invalid }
        return try .init(start: FHIRMeasurementInstant.exact(start), end: FHIRMeasurementInstant.exact(end))
    }

    private static func value(
        _ observation: Observation, shape: SensorKitOutputDefinition.ValueShape, quantityText: String?
    ) throws -> ClinicalOutputValue {
        switch shape {
        case .quantity:
            guard case .quantity(let quantity)? = observation.value, let quantityText else { throw FHIRValidationClient.invalid }
            let unit = try quantityUnit(quantity)
            return .quantity(value: quantityText, system: Canonicals.ucumSystem, code: unit)
        case .coded:
            guard case .codeableConcept(let concept)? = observation.value else { throw FHIRValidationClient.invalid }
            return try .coded(system: SensorKitContract.valueCodeSystem, code: coding(concept, system: SensorKitContract.valueCodeSystem))
        case .components:
            guard observation.value == nil, observation.component?.isEmpty == false else { throw FHIRValidationClient.invalid }
            return .components
        case .sampledData:
            guard case .sampledData(let data)? = observation.value else { throw FHIRValidationClient.invalid }
            try waveform(data)
            return .sampledData
        case .sampledDataComponent:
            guard observation.value == nil, observation.component?.count == 1,
                  case .sampledData? = observation.component?.first?.value else { throw FHIRValidationClient.invalid }
            return .components
        }
    }

    private static func primaryCoding(_ concept: CodeableConcept) throws -> (system: String, code: String) {
        guard concept.coding?.count == 1, let coding = concept.coding?.first,
              let system = coding.system?.value?.url.absoluteString, !system.isEmpty,
              let code = coding.code?.value?.string, !code.isEmpty else { throw FHIRValidationClient.invalid }
        return (system, code)
    }

    private static func waveform(_ data: SampledData) throws {
        guard let dimensions = data.dimensions.value?.integer, dimensions > 0,
              let period = data.period.value?.decimal, !period.isNaN, period > 0,
              let origin = data.origin.value?.value?.decimal, !origin.isNaN,
              data.origin.system == Canonicals.ucum, data.origin.code?.value?.string.isEmpty == false,
              let samples = data.data?.value?.string, !samples.isEmpty else { throw FHIRValidationClient.invalid }
        var count = 0
        for value in samples.split(separator: " ", omittingEmptySubsequences: false) {
            guard ["E", "U", "L"].contains(value) || Double(value).map({ $0.isFinite }) == true else { throw FHIRValidationClient.invalid }
            count += 1
        }
        guard count.isMultiple(of: Int(dimensions)) else { throw FHIRValidationClient.invalid }
    }

    private static func coding(_ concept: CodeableConcept, system: String) throws -> String {
        let codings = (concept.coding ?? []).filter { $0.system?.value?.url.absoluteString == system }
        guard codings.count == 1, let code = codings.first?.code?.value?.string, !code.isEmpty else { throw FHIRValidationClient.invalid }
        return code
    }

    private static func quantityUnit(_ quantity: Quantity) throws -> String {
        guard quantity.comparator == nil, let value = quantity.value?.value?.decimal, !value.isNaN, value >= 0,
              quantity.system == Canonicals.ucum, let unit = quantity.code?.value?.string, !unit.isEmpty else {
            throw FHIRValidationClient.invalid
        }
        return unit
    }

    private static func focus(_ references: [Reference], contract: SensorKitStructuredContract) throws {
        guard references.isEmpty || (contract == .visit && references.count == 1) else { throw FHIRValidationClient.invalid }
        for reference in references {
            guard reference.reference == nil, reference.type?.value?.url.absoluteString == ResourceType.location.rawValue,
                  reference.extension?.isEmpty != false, let identifier = reference.identifier else { throw FHIRValidationClient.invalid }
            _ = try BusinessIdentifier(identifier)
        }
    }

    private static func components(
        _ values: [ObservationComponent], bounds outer: ClinicalMeasurementBounds, contract: SensorKitStructuredContract
    ) throws {
        for component in values {
            guard component.dataAbsentReason == nil else { throw FHIRValidationClient.invalid }
            let system = contract == .electrocardiogram ? SensorKitContract.ecgLeadCodeSystem : SensorKitContract.conceptCodeSystem
            _ = try coding(component.code, system: system)
            switch component.value {
            case .quantity(let quantity): _ = try quantityUnit(quantity)
            case .codeableConcept(let concept): _ = try coding(concept, system: SensorKitContract.valueCodeSystem)
            case .sampledData(let data) where contract == .electrocardiogram: try waveform(data)
            case .period(let period) where contract == .visit:
                let interval = try bounds(period)
                guard let end = interval.end, let outerEnd = outer.end,
                      interval.start >= outer.start, end <= outerEnd else { throw FHIRValidationClient.invalid }
            default: throw FHIRValidationClient.invalid
            }
        }
    }
}
