//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveFHIRContract
import ModelsR4


/// Component values remain in the immutable record; projection verifies every required member before admission.
enum FHIRComponentProjection {
    static func validate(_ observation: Observation, measurement: FHIRMeasurementDefinition) throws {
        if measurement.profile == Profile.healthkitAudiogramPanel {
            try FHIRHealthKitAudiogramBoundary.validate(observation, measurement: measurement)
            return
        }
        guard measurement.valueShape == .components, observation.value == nil,
              !measurement.components.isEmpty, let components = observation.component,
              components.count == measurement.components.count else { throw FHIRValidationClient.invalid }
        for required in measurement.components {
            let matches = components.filter { component in
                component.code.coding?.contains(where: {
                    $0.system?.value?.url.absoluteString == required.code.system && $0.code?.value?.string == required.code.value
                }) == true
            }
            guard matches.count == 1, let component = matches.first, component.extension?.isEmpty != false, let contract = required.quantity,
                  case .quantity(let quantity)? = component.value, quantity.value?.value != nil,
                  quantity.comparator == nil, quantity.system?.value?.url.absoluteString == contract.system,
                  quantity.code?.value?.string == contract.code, component.dataAbsentReason == nil else {
                throw FHIRValidationClient.invalid
            }
        }
    }

    /// The full validator owns required/repeated cardinalities. Retain only declared graph-free component shapes.
    static func validateSupplemental(_ observation: Observation, measurement: FHIRMeasurementDefinition) throws {
        for component in observation.component ?? [] {
            guard component.extension?.isEmpty != false else { throw FHIRValidationClient.invalid }
            if try retainedHeartRateMotionContext(component, measurement: measurement) { continue }
            let contracts = measurement.components.filter { contract in
                component.code.coding?.contains(where: {
                    $0.system?.value?.url.absoluteString == contract.code.system && $0.code?.value?.string == contract.code.value
                }) == true
            }
            guard contracts.count == 1, let contract = contracts.first, component.dataAbsentReason == nil else {
                throw FHIRValidationClient.invalid
            }
            switch component.value {
            case .quantity(let quantity):
                guard let expected = contract.quantity, quantity.value?.value != nil, quantity.comparator == nil,
                      quantity.system?.value?.url.absoluteString == expected.system,
                      quantity.code?.value?.string == expected.code else { throw FHIRValidationClient.invalid }
            case .codeableConcept(let concept):
                let expected = contract.resultCodeSystem
                    ?? (measurement.profile == Profile.healthkitInsulinDelivery
                        ? Canonicals.healthKitInsulinDeliveryReason.value?.url.absoluteString : nil)
                guard let expected, concept.coding?.contains(where: { $0.system?.value?.url.absoluteString == expected }) == true else {
                    throw FHIRValidationClient.invalid
                }
            default: throw FHIRValidationClient.invalid
            }
        }
    }

    private static func retainedHeartRateMotionContext(
        _ component: ObservationComponent, measurement: FHIRMeasurementDefinition
    ) throws -> Bool {
        guard measurement.profile == Profile.groveMobileHeartRate,
              component.code.coding?.contains(where: {
                  $0.system == Canonicals.healthKitMetadataKey
                      && $0.code?.value?.string == FHIRMeasurementCatalog.healthKitHeartRateMotionContextCode
              }) == true else {
            return false
        }
        guard case .codeableConcept(let value)? = component.value, component.dataAbsentReason == nil,
              value.coding?.contains(where: { $0.system == Canonicals.healthKitHeartRateMotionContext }) == true else {
            throw FHIRValidationClient.invalid
        }
        return true
    }
}
