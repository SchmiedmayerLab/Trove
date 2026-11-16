// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import GroveFHIRContract
import ModelsR4


/// Preserves exact native test details while refusing undeclared component meanings and graph edges.
/// These checks supplement full IG validation; component numbers remain in the original record bytes.
enum FHIRHealthKitAudiogramBoundary {
    private struct Coordinate: Hashable {
        let ear: String
        let frequency: Decimal
    }

    static var url: String { Canonicals.healthKitAudiogramTestDetails.value?.url.absoluteString ?? "" }

    static func validate(_ observation: Observation, measurement: FHIRMeasurementDefinition) throws {
        guard measurement.profile == Profile.healthkitAudiogramPanel, observation.value == nil,
              let components = observation.component, (1...60).contains(components.count),
              let sensitivity = measurement.components.first?.quantity else { throw FHIRValidationClient.invalid }
        var coordinates: Set<Coordinate> = []
        for component in components {
            guard component.dataAbsentReason == nil, case .quantity(let value)? = component.value else {
                throw FHIRValidationClient.invalid
            }
            _ = try quantity(value, system: sensitivity.system, code: sensitivity.code)
            let coordinate = try details(component, system: sensitivity.system, code: sensitivity.code)
            guard coordinates.insert(coordinate).inserted else { throw FHIRValidationClient.invalid }
            try coding(component, at: coordinate, measurement: measurement)
        }
        guard Set(coordinates.map(\.frequency)).count <= 30 else { throw FHIRValidationClient.invalid }
    }

    private static func details(_ component: ObservationComponent, system: String, code: String) throws -> Coordinate {
        guard let extensions = component.extension, extensions.count == 1, let details = extensions.first,
              details.url.value?.url.absoluteString == url, details.value == nil,
              let fields = details.extension, (3...5).contains(fields.count) else { throw FHIRValidationClient.invalid }
        var values: [String: Extension] = [:]
        let allowed: Set<String> = ["frequency", "ear", "conduction", "masked", "clampingRange"]
        for field in fields {
            guard let name = field.url.value?.url.absoluteString, allowed.contains(name), field.extension?.isEmpty != false,
                  values.updateValue(field, forKey: name) == nil else { throw FHIRValidationClient.invalid }
        }
        guard case .quantity(let frequency)? = values["frequency"]?.value,
              case .code(let ear)? = values["ear"]?.value, let ear = ear.value?.string, ["left", "right"].contains(ear),
              case .code(let conduction)? = values["conduction"]?.value, conduction.value?.string == "air" else {
            throw FHIRValidationClient.invalid
        }
        let hertz = try quantity(frequency, system: system, code: "Hz")
        guard hertz > 0 else { throw FHIRValidationClient.invalid }
        if let masking = values["masked"] {
            guard case .boolean(let value)? = masking.value, value.value != nil else { throw FHIRValidationClient.invalid }
        }
        if let clamping = values["clampingRange"] {
            guard case .range(let range)? = clamping.value, range.low != nil || range.high != nil,
                  range.extension?.isEmpty != false else { throw FHIRValidationClient.invalid }
            let low = try range.low.map { try quantity($0, system: system, code: code) }
            let high = try range.high.map { try quantity($0, system: system, code: code) }
            if let low, let high, low >= high { throw FHIRValidationClient.invalid }
        }
        return Coordinate(ear: ear, frequency: hertz)
    }

    private static func quantity(_ value: Quantity, system: String, code: String) throws -> Decimal {
        guard value.system?.value?.url.absoluteString == system, value.code?.value?.string == code,
              value.comparator == nil, value.extension?.isEmpty != false,
              let number = value.value?.value?.decimal, !number.isNaN else { throw FHIRValidationClient.invalid }
        return number
    }

    private static func coding(_ component: ObservationComponent, at coordinate: Coordinate, measurement: FHIRMeasurementDefinition) throws {
        let matching = measurement.components.filter { contract in
            let parts = contract.id.split(separator: "-", maxSplits: 1)
            return parts.count == 2 && parts[0] == coordinate.ear && Decimal(string: String(parts[1])) == coordinate.frequency
        }
        if let contract = matching.first {
            guard matching.count == 1, component.code.coding?.count == 1, let coding = component.code.coding?.first,
                  coding.system?.value?.url.absoluteString == contract.code.system,
                  coding.code?.value?.string == contract.code.value else { throw FHIRValidationClient.invalid }
        } else {
            guard component.code.coding?.isEmpty != false, component.code.text?.value?.string.isEmpty == false else {
                throw FHIRValidationClient.invalid
            }
        }
    }

    /// A bounded, graph-free allowlist for nested extension locations; numbers are never converted or re-encoded here.
    static func validateLocations(_ object: [String: Any]) throws {
        guard Set(object.keys) == ["url", "extension"], object["url"] as? String == url,
              let fields = object["extension"] as? [[String: Any]], (3...5).contains(fields.count) else {
            throw FHIRValidationClient.invalid
        }
        for field in fields { try fieldLocations(field) }
    }

    private static func fieldLocations(_ field: [String: Any]) throws {
        guard let name = field["url"] as? String else { throw FHIRValidationClient.invalid }
        switch name {
        case "frequency":
            guard Set(field.keys) == ["url", "valueQuantity"] else { throw FHIRValidationClient.invalid }
            try quantityLocations(field["valueQuantity"])
        case "ear", "conduction":
            guard Set(field.keys) == ["url", "valueCode"], field["valueCode"] is String else { throw FHIRValidationClient.invalid }
        case "masked":
            guard Set(field.keys) == ["url", "valueBoolean"], field["valueBoolean"] is Bool else { throw FHIRValidationClient.invalid }
        case "clampingRange": try rangeLocations(field)
        default: throw FHIRValidationClient.invalid
        }
    }

    private static func rangeLocations(_ field: [String: Any]) throws {
        guard Set(field.keys) == ["url", "valueRange"], let range = field["valueRange"] as? [String: Any],
              !range.isEmpty, Set(range.keys).isSubset(of: ["low", "high"]) else { throw FHIRValidationClient.invalid }
        for value in range.values { try quantityLocations(value) }
    }

    private static func quantityLocations(_ value: Any?) throws {
        guard let quantity = value as? [String: Any], Set(quantity.keys).isSubset(of: ["value", "unit", "system", "code"]),
              quantity.values.allSatisfy({ !($0 is [String: Any]) && !($0 is [Any]) }) else { throw FHIRValidationClient.invalid }
    }
}
