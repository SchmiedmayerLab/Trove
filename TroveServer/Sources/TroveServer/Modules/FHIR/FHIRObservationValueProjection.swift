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


/// Searchable values from a fully validated observation; original bytes retain all source codings.
struct FHIRObservationValueProjection {
    let profile: String
    let measurementBounds: ClinicalMeasurementBounds

    var start: Date { measurementBounds.startDate }
    var end: Date? { measurementBounds.endDate }
    let value: ClinicalOutputValue
    let codeSystem: String
    let code: String

    init(observation: Observation, quantityText: String?) throws {
        guard observation.status.value == .final,
              observation.specimen == nil,
              observation.basedOn?.isEmpty != false, observation.partOf?.isEmpty != false, observation.encounter == nil else {
            throw FHIRValidationClient.invalid
        }
        let profiles = (observation.meta?.profile ?? []).compactMap { $0.value?.url.absoluteString }
        let supported = (CollectionObservationProfile.allCases.map(\.rawValue) + [FHIRWorkoutProjection.segmentProfile])
            .filter(profiles.contains)
        guard supported.count == 1, let profile = supported.first else { throw FHIRValidationClient.invalid }
        let capability = CollectionObservationProfile(rawValue: profile)
        if let capability, let sensor = try FHIRSensorKitObservationProjection.project(
            observation, capability: capability, quantityText: quantityText
        ) {
            self.init(sensor: sensor, profile: profile)
        } else {
            try self.init(mobile: observation, quantityText: quantityText, profile: profile, capability: capability)
        }
    }

    private init(sensor: FHIRSensorKitObservationProjection, profile: String) {
        self.profile = profile
        self.measurementBounds = sensor.measurementBounds
        self.value = sensor.value
        self.codeSystem = sensor.codeSystem
        self.code = sensor.code
    }

    private init(mobile observation: Observation, quantityText: String?, profile: String, capability: CollectionObservationProfile?) throws {
        let workout = profile == CollectionObservationProfile.workout.rawValue || profile == FHIRWorkoutProjection.segmentProfile
        guard observation.focus?.isEmpty != false else { throw FHIRValidationClient.invalid }
        let measurement = capability?.measurement
        guard workout || capability == .food || capability == .electrocardiogram || observation.hasMember?.isEmpty != false else {
            throw FHIRValidationClient.invalid
        }
        if !workout, capability != .food, let measurement, measurement.valueShape != .components {
            try FHIRComponentProjection.validateSupplemental(observation, measurement: measurement)
        }
        let coding = try Self.measurementCoding(observation, measurement: measurement)
        self.profile = profile
        self.codeSystem = coding.system
        self.code = coding.code
        if let capability, capability == .food {
            try FHIRFoodProjection.validate(observation)
            measurementBounds = try Self.effectiveTime(observation, capability: capability)
            value = .group
        } else if let capability, capability == .electrocardiogram {
            try FHIRHealthKitECGBoundary.validateWaveform(observation)
            measurementBounds = try Self.effectiveTime(observation, capability: capability)
            value = .components
        } else if let capability, let measurement, measurement.valueShape == .quantity {
            guard case .quantity(let quantity)? = observation.value, let quantityText,
                  quantity.value?.value != nil, quantity.comparator == nil,
                  let system = quantity.system?.value?.url.absoluteString, let unit = quantity.code?.value?.string,
                  system == measurement.quantity?.system, unit == measurement.quantity?.code else {
                throw FHIRValidationClient.invalid
            }
            measurementBounds = try Self.effectiveTime(observation, capability: capability)
            value = .quantity(value: quantityText, system: system, code: unit)
        } else if let capability, let measurement, measurement.valueShape == .components {
            try FHIRComponentProjection.validate(observation, measurement: measurement)
            measurementBounds = try Self.effectiveTime(observation, capability: capability)
            value = .components
        } else {
            guard let temporalCapability = capability ?? (workout ? .workout : nil),
                  case .codeableConcept(let concept)? = observation.value else { throw FHIRValidationClient.invalid }
            let systems = workout ? [FHIRWorkoutProjection.activitySystem, FHIRWorkoutProjection.segmentSystem]
                : measurement?.resultCodeSystem.map { [$0] } ?? []
            let codings = (concept.coding ?? []).filter { systems.contains($0.system?.value?.url.absoluteString ?? "") }
            guard codings.count == 1, let result = codings.first,
                  let system = result.system?.value?.url.absoluteString, let code = result.code?.value?.string else {
                throw FHIRValidationClient.invalid
            }
            measurementBounds = try Self.effectiveTime(observation, capability: temporalCapability)
            value = .coded(system: system, code: code)
        }
    }

    private static func measurementCoding(
        _ observation: Observation, measurement: FHIRMeasurementDefinition?
    ) throws -> (system: String, code: String) {
        let codings = observation.code.coding ?? []
        let selected = measurement.map { descriptor in
            codings.filter {
                $0.system?.value?.url.absoluteString == descriptor.code.system && $0.code?.value?.string == descriptor.code.value
            }
        } ?? codings
        guard selected.count == 1, let coding = selected.first,
              let system = coding.system?.value?.url.absoluteString, let code = coding.code?.value?.string else {
            throw FHIRValidationClient.invalid
        }
        for required in measurement?.requiredCodings ?? [] {
            guard codings.contains(where: {
                $0.system?.value?.url.absoluteString == required.system && $0.code?.value?.string == required.value
            }) else {
                throw FHIRValidationClient.invalid
            }
        }
        return (system, code)
    }

    private static func effectiveTime(
        _ observation: Observation, capability: CollectionObservationProfile
    ) throws -> ClinicalMeasurementBounds {
        switch observation.effective {
        case .dateTime(let instant) where capability.permitsEffectiveTime(hasEnd: false):
            return try .init(start: Self.instant(instant))
        case .period(let period) where capability.permitsEffectiveTime(hasEnd: true):
            let start = try Self.instant(period.start)
            let end = try Self.instant(period.end)
            guard end >= start else { throw FHIRValidationClient.invalid }
            return try .init(start: start, end: end)
        default:
            throw FHIRValidationClient.invalid
        }
    }

    private static func instant(_ primitive: FHIRPrimitive<DateTime>?) throws -> RecordedInstant {
        guard let value = primitive?.value, value.time != nil, value.timeZone != nil else { throw FHIRValidationClient.invalid }
        return try FHIRMeasurementInstant.exact(value)
    }
}
