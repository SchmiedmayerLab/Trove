//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract


/// Grove has already validated JSON grammar, Unicode, duplicate keys and record identity.
/// Its canonical bytes contain no inter-token whitespace. Bound recursion independently.
private struct StudyProjectionJSONReader {
    let bytes: [UInt8]
    var offset = 0

    private var current: UInt8? { offset < bytes.count ? bytes[offset] : nil }

    mutating func read(depth: Int) throws -> StudyProjectionJSON {
        guard depth <= ValidatedQuantityLexemes.maximumDepth, let byte = current else { throw FHIRValidationClient.invalid }
        switch byte {
        case UInt8(ascii: "{"): return try object(depth: depth + 1)
        case UInt8(ascii: "["): return try array(depth: depth + 1)
        case UInt8(ascii: "\""): return .scalar(try quoted())
        default:
            let start = offset
            while let byte = current, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]")].contains(byte) { offset += 1 }
            guard offset > start else { throw FHIRValidationClient.invalid }
            return .scalar(Data(bytes[start..<offset]))
        }
    }

    private mutating func object(depth: Int) throws -> StudyProjectionJSON {
        try consume(UInt8(ascii: "{"))
        var members: [String: StudyProjectionJSON] = [:]
        if current != UInt8(ascii: "}") {
            while true {
                let key = try JSONDecoder().decode(String.self, from: quoted())
                try consume(UInt8(ascii: ":"))
                guard members.updateValue(try read(depth: depth), forKey: key) == nil else { throw FHIRValidationClient.invalid }
                if current != UInt8(ascii: ",") { break }
                offset += 1
            }
        }
        try consume(UInt8(ascii: "}"))
        return .object(members)
    }

    private mutating func array(depth: Int) throws -> StudyProjectionJSON {
        try consume(UInt8(ascii: "["))
        var values: [StudyProjectionJSON] = []
        if current != UInt8(ascii: "]") {
            while true {
                values.append(try read(depth: depth))
                if current != UInt8(ascii: ",") { break }
                offset += 1
            }
        }
        try consume(UInt8(ascii: "]"))
        return .array(values)
    }

    private mutating func quoted() throws -> Data {
        let start = offset
        try consume(UInt8(ascii: "\""))
        while let byte = current {
            offset += 1
            if byte == UInt8(ascii: "\"") {
                return Data(bytes[start..<offset])
            }
            if byte == UInt8(ascii: "\\") {
                guard current != nil else { throw FHIRValidationClient.invalid }
                offset += 1
            }
        }
        throw FHIRValidationClient.invalid
    }

    private mutating func consume(_ byte: UInt8) throws {
        guard current == byte else { throw FHIRValidationClient.invalid }
        offset += 1
    }
}


/// Edits already validated canonical record JSON without decoding any numeric value.
/// Scalars retain their original tokens; only explicitly replaced strings are re-encoded.
/// This is a projection implementation detail, not a general JSON or FHIR validator.
indirect enum StudyProjectionJSON: Sendable {
    case object([String: Self])
    case array([Self])
    case scalar(Data)

    enum Failure: Error, Equatable {
        case outputTooLarge
    }

    // swiftlint:disable:next discouraged_optional_collection - Wrong JSON type differs from an empty object.
    var object: [String: Self]? {
        guard case .object(let value) = self else {
            return nil
        }
        return value
    }

    // swiftlint:disable:next discouraged_optional_collection - Wrong JSON type differs from an empty array.
    var array: [Self]? {
        guard case .array(let value) = self else {
            return nil
        }
        return value
    }

    var string: String? {
        guard case .scalar(let bytes) = self, bytes.first == UInt8(ascii: "\"") else {
            return nil
        }
        return try? JSONDecoder().decode(String.self, from: bytes)
    }

    static func string(_ value: String) throws -> Self {
        .scalar(try JSONEncoder().encode(value))
    }

    static func read(_ record: ExchangeRecord) throws -> Self {
        guard record.json.count <= FHIRValidationClient.maximumBytes else { throw FHIRValidationClient.invalid }
        var reader = StudyProjectionJSONReader(bytes: Array(record.json))
        let result = try reader.read(depth: 0)
        guard reader.offset == reader.bytes.count else { throw FHIRValidationClient.invalid }
        return result
    }

    func encoded(maximumBytes: Int = StudyExportLimits.standard.bundleBytes) throws -> Data {
        var result = Data()
        try append(to: &result, maximumBytes: maximumBytes)
        return result
    }

    private func append(to result: inout Data, maximumBytes: Int) throws {
        switch self {
        case .scalar(let bytes): try append(bytes, to: &result, maximumBytes: maximumBytes)
        case .array(let values):
            try append(UInt8(ascii: "["), to: &result, maximumBytes: maximumBytes)
            for (index, value) in values.enumerated() {
                if index > 0 { try append(UInt8(ascii: ","), to: &result, maximumBytes: maximumBytes) }
                try value.append(to: &result, maximumBytes: maximumBytes)
            }
            try append(UInt8(ascii: "]"), to: &result, maximumBytes: maximumBytes)
        case .object(let members):
            try append(UInt8(ascii: "{"), to: &result, maximumBytes: maximumBytes)
            for (index, key) in members.keys.sorted().enumerated() {
                guard let value = members[key] else { throw FHIRValidationClient.invalid }
                if index > 0 { try append(UInt8(ascii: ","), to: &result, maximumBytes: maximumBytes) }
                try append(JSONEncoder().encode(key), to: &result, maximumBytes: maximumBytes)
                try append(UInt8(ascii: ":"), to: &result, maximumBytes: maximumBytes)
                try value.append(to: &result, maximumBytes: maximumBytes)
            }
            try append(UInt8(ascii: "}"), to: &result, maximumBytes: maximumBytes)
        }
    }

    private func append(_ bytes: Data, to result: inout Data, maximumBytes: Int) throws {
        guard bytes.count <= maximumBytes - result.count else { throw Failure.outputTooLarge }
        result.append(bytes)
    }

    private func append(_ byte: UInt8, to result: inout Data, maximumBytes: Int) throws {
        guard result.count < maximumBytes else { throw Failure.outputTooLarge }
        result.append(byte)
    }

    subscript(_ key: String) -> Self? { object?[key] }
}
