//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// A token walker with only the paths needed for extraction; no JSON object graph is built.
private struct QuantityLexemeScanner {
    private enum Path {
        case root, entries, entry(Int), resource(Int), quantity(Int), value(Int), resourceType(Int), unrelated

        func member(_ key: String) -> Self {
            switch (self, key) {
            case (.root, "entry"): .entries
            case (.entry(let ordinal), "resource"): .resource(ordinal)
            case (.resource(let ordinal), "valueQuantity"): .quantity(ordinal)
            case (.resource(let ordinal), "resourceType"): .resourceType(ordinal)
            case (.quantity(let ordinal), "value"): .value(ordinal)
            default: .unrelated
            }
        }
    }

    let bytes: [UInt8]
    private var offset = 0
    private var quantities: [Int: String] = [:]
    private var observations: Set<Int> = []

    private var current: UInt8? { offset < bytes.count ? bytes[offset] : nil }

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func extract() throws -> [Int: String] {
        whitespace()
        guard current == 0x7B else { throw ValidatedQuantityLexemes.Failure.invalidJSON }
        try value(at: .root, depth: 0)
        whitespace()
        guard offset == bytes.count else { throw ValidatedQuantityLexemes.Failure.invalidJSON }
        return quantities.filter { observations.contains($0.key) }
    }

    private mutating func value(at path: Path, depth: Int) throws {
        guard depth <= ValidatedQuantityLexemes.maximumDepth else { throw ValidatedQuantityLexemes.Failure.nestingLimit }
        whitespace()
        if current == 0x7B || current == 0x5B {
            guard depth < ValidatedQuantityLexemes.maximumDepth else { throw ValidatedQuantityLexemes.Failure.nestingLimit }
        }
        if case .value(let ordinal) = path {
            quantities[ordinal] = try number()
            return
        }
        switch current {
        case 0x7B: try object(at: path, depth: depth + 1)
        case 0x5B: try array(at: path, depth: depth + 1)
        default: try scalar(at: path)
        }
    }

    private mutating func scalar(at path: Path) throws {
        guard let byte = current else { throw ValidatedQuantityLexemes.Failure.invalidJSON }
        switch byte {
        case 0x22:
            let text = try string()
            if case .resourceType(let ordinal) = path, text == "Observation" {
                observations.insert(ordinal)
            }
        case 0x74: try literal([0x74, 0x72, 0x75, 0x65])
        case 0x66: try literal([0x66, 0x61, 0x6C, 0x73, 0x65])
        case 0x6E: try literal([0x6E, 0x75, 0x6C, 0x6C])
        case 0x2D, 0x30...0x39: _ = try number()
        default: throw ValidatedQuantityLexemes.Failure.invalidJSON
        }
    }

    private mutating func object(at path: Path, depth: Int) throws {
        try consume(0x7B)
        whitespace()
        if current == 0x7D {
            offset += 1
            return
        }
        var keys: Set<String> = []
        while true {
            whitespace()
            let key = try string()
            guard keys.insert(key).inserted else { throw ValidatedQuantityLexemes.Failure.invalidJSON }
            whitespace()
            try consume(0x3A)
            try value(at: path.member(key), depth: depth)
            whitespace()
            if current == 0x7D {
                offset += 1
                return
            }
            try consume(0x2C)
        }
    }

    private mutating func array(at path: Path, depth: Int) throws {
        try consume(0x5B)
        whitespace()
        if current == 0x5D {
            offset += 1
            return
        }
        var ordinal = 0
        while true {
            let elementPath: Path
            if case .entries = path { elementPath = .entry(ordinal) } else { elementPath = .unrelated }
            try value(at: elementPath, depth: depth)
            ordinal += 1
            whitespace()
            if current == 0x5D {
                offset += 1
                return
            }
            try consume(0x2C)
        }
    }

    private mutating func string() throws -> String {
        let start = offset
        try consume(0x22)
        while let byte = current {
            guard byte >= 0x20 else { throw ValidatedQuantityLexemes.Failure.invalidJSON }
            offset += 1
            if byte == 0x22 {
                // Decode just this string for escaped member names and Unicode validity.
                // JSONDecoder never sees a number, so no Decimal conversion occurs here.
                guard let decoded = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) else {
                    throw ValidatedQuantityLexemes.Failure.invalidJSON
                }
                return decoded
            }
            if byte == 0x5C {
                guard current != nil else { throw ValidatedQuantityLexemes.Failure.invalidJSON }
                offset += 1
            }
        }
        throw ValidatedQuantityLexemes.Failure.invalidJSON
    }

    private mutating func number() throws -> String {
        let start = offset
        if current == 0x2D { offset += 1 }
        if current == 0x30 {
            offset += 1
        } else {
            guard let byte = current, (0x31...0x39).contains(byte) else { throw ValidatedQuantityLexemes.Failure.invalidJSON }
            digits()
        }
        if current == 0x2E {
            offset += 1
            try requiredDigits()
        }
        if current == 0x65 || current == 0x45 {
            offset += 1
            if current == 0x2B || current == 0x2D { offset += 1 }
            try requiredDigits()
        }
        return String(decoding: bytes[start..<offset], as: UTF8.self)
    }

    private mutating func requiredDigits() throws {
        let start = offset
        digits()
        guard offset > start else { throw ValidatedQuantityLexemes.Failure.invalidJSON }
    }

    private mutating func digits() {
        while let byte = current, (0x30...0x39).contains(byte) { offset += 1 }
    }

    private mutating func whitespace() {
        while let byte = current, [0x20, 0x09, 0x0A, 0x0D].contains(byte) { offset += 1 }
    }

    private mutating func consume(_ byte: UInt8) throws {
        guard current == byte else { throw ValidatedQuantityLexemes.Failure.invalidJSON }
        offset += 1
    }

    private mutating func literal(_ expected: [UInt8]) throws {
        for byte in expected { try consume(byte) }
    }
}


/// Preserves number tokens from already validated event bytes. This does not validate FHIR.
/// Keys are Bundle.entry ordinals, never resource IDs or positions within an Observation array.
enum ValidatedQuantityLexemes {
    enum Failure: Error, Equatable {
        case invalidJSON
        case inputTooLarge
        case nestingLimit
    }

    static let maximumBytes = 4 * 1024 * 1024
    static let maximumDepth = 64

    static func extract(from data: Data) throws -> [Int: String] {
        guard data.count <= maximumBytes else { throw Failure.inputTooLarge }
        guard String(data: data, encoding: .utf8) != nil else { throw Failure.invalidJSON }
        var scanner = QuantityLexemeScanner(bytes: Array(data))
        return try scanner.extract()
    }
}
