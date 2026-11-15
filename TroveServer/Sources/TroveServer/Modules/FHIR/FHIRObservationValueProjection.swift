//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import ModelsR4
import TroveAPITypes


/// Searchable values from a fully validated observation; original bytes retain all source codings.
struct FHIRObservationValueProjection {
    let profile: String
    let start: Date
    let end: Date?
    let value: ClinicalOutputValue
    let codeSystem: String
    let code: String

    init(observation: Observation, quantityText: String?) throws {
        guard observation.status.value == .final,
              let coding = observation.code.coding?.first, observation.code.coding?.count == 1,
              let codeSystem = coding.system?.value?.url.absoluteString, let code = coding.code?.value?.string,
              observation.focus?.isEmpty != false, observation.specimen == nil,
              observation.basedOn?.isEmpty != false, observation.partOf?.isEmpty != false, observation.encounter == nil else {
            throw FHIRValidationClient.invalid
        }
        let profiles = (observation.meta?.profile ?? []).compactMap { $0.value?.url.absoluteString }
        let supported = (CollectionObservationProfile.allCases.map(\.rawValue) + [FHIRWorkoutProjection.segmentProfile])
            .filter(profiles.contains)
        guard supported.count == 1, let profile = supported.first else { throw FHIRValidationClient.invalid }
        let workout = profile == CollectionObservationProfile.workout.rawValue || profile == FHIRWorkoutProjection.segmentProfile
        guard workout || (observation.component?.isEmpty != false && observation.hasMember?.isEmpty != false) else {
            throw FHIRValidationClient.invalid
        }
        self.profile = profile
        self.codeSystem = codeSystem
        self.code = code
        switch profile {
        case CollectionObservationProfile.heartRate.rawValue:
            guard case .dateTime(let instant)? = observation.effective,
                  case .quantity(let quantity)? = observation.value, let quantityText,
                  quantity.value?.value != nil, quantity.comparator == nil,
                  let system = quantity.system?.value?.url.absoluteString, let unit = quantity.code?.value?.string else {
                throw FHIRValidationClient.invalid
            }
            start = try Self.instant(instant)
            end = nil
            value = .quantity(value: quantityText, system: system, code: unit)
        default:
            guard case .period(let period)? = observation.effective,
                  case .codeableConcept(let concept)? = observation.value else { throw FHIRValidationClient.invalid }
            let lower = try Self.instant(period.start)
            let upper = try Self.instant(period.end)
            let systems = workout ? [FHIRWorkoutProjection.activitySystem, FHIRWorkoutProjection.segmentSystem]
                : [Canonicals.sleepStageCodeSystem.value?.url.absoluteString ?? ""]
            let codings = (concept.coding ?? []).filter { systems.contains($0.system?.value?.url.absoluteString ?? "") }
            guard lower <= upper, codings.count == 1, let stage = codings.first,
                  let system = stage.system?.value?.url.absoluteString, let code = stage.code?.value?.string else {
                throw FHIRValidationClient.invalid
            }
            start = lower
            end = upper
            value = .coded(system: system, code: code)
        }
    }

    private static func instant(_ primitive: FHIRPrimitive<DateTime>?) throws -> Date {
        guard let value = primitive?.value, value.time != nil, value.timeZone != nil else { throw FHIRValidationClient.invalid }
        let date = try value.asNSDate()
        guard CollectionMeasurementWindow.valid(date) else { throw FHIRValidationClient.invalid }
        return date
    }
}
