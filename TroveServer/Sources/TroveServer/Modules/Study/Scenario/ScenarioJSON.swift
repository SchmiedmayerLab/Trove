//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// A JSON value read without a schema, so that a malformed condition keeps its item path instead of failing the whole resource.
enum ScenarioJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    var bool: Bool? { // swiftlint:disable:this discouraged_optional_boolean
        if case .bool(let value) = self { value } else { nil }
    }

    var number: Double? {
        if case .number(let value) = self { value } else { nil }
    }

    var array: [Self]? { // swiftlint:disable:this discouraged_optional_collection
        if case .array(let value) = self { value } else { nil }
    }

    var object: [String: Self]? { // swiftlint:disable:this discouraged_optional_collection
        if case .object(let value) = self { value } else { nil }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: Self].self))
        }
    }

    /// The JSON form of a typed value.
    static func from(_ value: some Encodable) -> Self? {
        guard let data = try? JSONEncoder().encode(value) else {
            return nil
        }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// The typed value with this JSON form; `nil` when the JSON does not match the type.
    func converted<Value: Decodable>(to type: Value.Type) -> Value? {
        guard let data = try? JSONEncoder().encode(self) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    subscript(key: String) -> Self? {
        object?[key]
    }
}
