//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// One typed FHIR R4 answer value, or the expected value of an `enableWhen` condition.
enum ScenarioValue: Equatable, Sendable {
    case boolean(Bool)
    case decimal(Double)
    case integer(Int)
    case date(ScenarioTemporal)
    case dateTime(ScenarioTemporal)
    case time(ScenarioTemporal)
    case string(String)
    case uri(String)
    case coding(system: String?, code: String?)
    case quantity(Quantity)
    case reference(String?)
    case attachment

    struct Quantity: Equatable, Sendable {
        let value: Double?
        let comparator: String?
        let system: String?
        let code: String?
        var unit: String?
    }

    /// The result of an ordered comparison.
    enum Ordering: Equatable {
        case ordered(ComparisonResult)
        /// The values agree down to the coarser precision of the two, or their quantity units differ.
        case unknown
        /// The values are of different kinds and have no order.
        case incomparable
    }

    /// The FHIR type suffix of `value[x]` and `answer[x]`.
    var kind: String {
        switch self {
        case .boolean: "Boolean"
        case .decimal: "Decimal"
        case .integer: "Integer"
        case .date: "Date"
        case .dateTime: "DateTime"
        case .time: "Time"
        case .string: "String"
        case .uri: "Uri"
        case .coding: "Coding"
        case .quantity: "Quantity"
        case .reference: "Reference"
        case .attachment: "Attachment"
        }
    }

    private var number: Double? {
        switch self {
        case .decimal(let value): value
        case .integer(let value): Double(value)
        default: nil
        }
    }

    private var temporal: (value: ScenarioTemporal, isTime: Bool)? {
        switch self {
        case .date(let value), .dateTime(let value): (value, false)
        case .time(let value): (value, true)
        default: nil
        }
    }

    /// Reads a FHIR JSON value of the type that `kind` names; `nil` when the JSON does not hold that type.
    static func parse(kind: String, json: ScenarioJSON) -> Self? { // swiftlint:disable:this cyclomatic_complexity
        switch kind {
        case "Boolean": json.bool.map(Self.boolean)
        case "Decimal": json.number.map(Self.decimal)
        case "Integer": json.number.flatMap(integer(_:))
        case "Date": json.string.flatMap(ScenarioTemporal.date).map(Self.date)
        case "DateTime": json.string.flatMap(ScenarioTemporal.dateTime).map(Self.dateTime)
        case "Time": json.string.flatMap(ScenarioTemporal.time).map(Self.time)
        case "String": json.string.map(Self.string)
        case "Uri": json.string.map(Self.uri)
        case "Coding": json.object.flatMap(coding(_:))
        case "Quantity": json.object.flatMap(quantity(_:))
        case "Reference": json.object.flatMap { object in optionalString(object["reference"]).map(Self.reference) }
        case "Attachment": json.object.map { _ in .attachment }
        default: nil
        }
    }

    private static func integer(_ number: Double) -> Self? {
        guard number.rounded() == number, number >= Double(Int32.min), number <= Double(Int32.max) else {
            return nil
        }
        return .integer(Int(number))
    }

    private static func coding(_ object: [String: ScenarioJSON]) -> Self? {
        guard let system = optionalString(object["system"]), let code = optionalString(object["code"]) else {
            return nil
        }
        return .coding(system: system, code: code)
    }

    private static func quantity(_ object: [String: ScenarioJSON]) -> Self? {
        guard let comparator = optionalString(object["comparator"]),
              let unit = optionalString(object["unit"]),
              let system = optionalString(object["system"]),
              let code = optionalString(object["code"]) else {
            return nil
        }
        let value: Double?
        switch object["value"] {
        case nil: value = nil
        case .number(let number): value = number
        default: return nil
        }
        return .quantity(.init(value: value, comparator: comparator, system: system, code: code, unit: unit))
    }

    /// `.some(nil)` for an absent member, `nil` for a member that is not a string.
    private static func optionalString(_ json: ScenarioJSON?) -> String?? {
        switch json {
        case nil: .some(nil)
        case .string(let value): .some(value)
        default: nil
        }
    }

    /// Whether an answer equals the expected value. Values of different kinds are not equal; `nil` when equality is unknown.
    func equals(_ expected: Self) -> Bool? { // swiftlint:disable:this discouraged_optional_boolean
        switch (self, expected) {
        case let (.boolean(answer), .boolean(value)):
            return answer == value
        case let (.string(answer), .string(value)):
            return answer.utf8.elementsEqual(value.utf8)
        case let (.coding(system, code), .coding(expectedSystem, expectedCode)):
            // System and code must both be equal; a coding without a system equals only another coding without one.
            guard let code, let expectedCode else {
                return false
            }
            return code == expectedCode && system == expectedSystem
        case let (.reference(answer), .reference(value)):
            return answer != nil && answer == value
        default:
            switch order(comparedTo: expected) {
            case .ordered(let result): return result == .orderedSame
            case .unknown: return nil
            case .incomparable: return false
            }
        }
    }

    func order(comparedTo expected: Self) -> Ordering {
        if let answer = number, let value = expected.number {
            return .ordered(answer < value ? .orderedAscending : answer > value ? .orderedDescending : .orderedSame)
        }
        if let answer = temporal, let value = expected.temporal, answer.isTime == value.isTime {
            return answer.value.compare(to: value.value).map(Ordering.ordered) ?? .unknown
        }
        guard case .quantity(let answer) = self, case .quantity(let threshold) = expected else {
            return .incomparable
        }
        // Units are not converted: a quantity in another unit, or a bounded quantity, has no known order.
        let sameUnit: Bool
        if let code = threshold.code {
            sameUnit = answer.code == code && (threshold.system == nil || answer.system == threshold.system)
        } else if let unit = threshold.unit {
            sameUnit = answer.unit == unit
        } else {
            // A threshold without a unit orders only quantities without a unit.
            sameUnit = answer.code == nil && answer.unit == nil
        }
        guard sameUnit, answer.comparator == nil, let measured = answer.value, let value = threshold.value else {
            return .unknown
        }
        return Self.decimal(measured).order(comparedTo: .decimal(value))
    }
}
