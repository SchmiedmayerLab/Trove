//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//


/// A BCP 47 language tag of written content in canonical case: a language, optionally followed by a script and a
/// region, for example `de`, `zh-Hant` or `pt-BR`.
///
/// A region is not required, and distinct tags stay distinct. The special codes `und`, `mul`, `zxx`, `mis` and the
/// private-use range `qaa`–`qtz` name no language of written content and are rejected.
///
/// Note: This type is mapped from Components.Schemas.LanguageTag via typeOverrides in the OpenAPI generator config files.
public struct LanguageTag: RawRepresentable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public var description: String {
        rawValue
    }

    /// Fails unless `rawValue` is a language with an optional script and region, each in canonical case.
    public init?(rawValue: String) {
        var subtags = rawValue.split(separator: "-", omittingEmptySubsequences: false)[...]
        if let language = subtags.first, Self.isSpecial(language) {
            return nil
        }
        func next(_ matches: (Substring) -> Bool) -> Bool {
            guard let subtag = subtags.first, matches(subtag) else {
                return false
            }
            subtags.removeFirst()
            return true
        }
        guard next({ (2...3).contains($0.count) && $0.allSatisfy(\.isLowercaseASCIILetter) }) else {
            return nil
        }
        _ = next { $0.count == 4 && $0.first?.isUppercaseASCIILetter == true && $0.dropFirst().allSatisfy(\.isLowercaseASCIILetter) }
        _ = next { ($0.count == 2 && $0.allSatisfy(\.isUppercaseASCIILetter)) || ($0.count == 3 && $0.allSatisfy(\.isASCIIDigit)) }
        guard subtags.isEmpty else {
            return nil
        }
        self.rawValue = rawValue
    }

    private static func isSpecial(_ language: Substring) -> Bool {
        if ["und", "mul", "zxx", "mis"].contains(language) {
            return true
        }
        let letters = Array(language)
        return letters.count == 3 && letters[0] == "q" && ("a"..."t").contains(letters[1])
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}


extension LanguageTag: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let tag = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a BCP 47 language tag such as de, zh-Hant or pt-BR")
        }
        self = tag
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}


extension LanguageTag: CodingKeyRepresentable {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    public var codingKey: any CodingKey {
        Key(stringValue: rawValue)
    }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(rawValue: codingKey.stringValue)
    }
}


extension Character {
    fileprivate var isLowercaseASCIILetter: Bool {
        isASCII && isLowercase && isLetter
    }

    fileprivate var isUppercaseASCIILetter: Bool {
        isASCII && isUppercase && isLetter
    }

    fileprivate var isASCIIDigit: Bool {
        isASCII && isWholeNumber
    }
}
