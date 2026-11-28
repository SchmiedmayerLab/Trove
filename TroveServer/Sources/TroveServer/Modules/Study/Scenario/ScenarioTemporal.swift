//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// A FHIR `date`, `dateTime` or `time` value with the precision its text states.
struct ScenarioTemporal: Equatable, Sendable {
    /// Year, month and day, as far as the value states them. Empty for a time.
    let date: [Int]
    /// Seconds since 1970-01-01T00:00:00Z for a date-time with a time, or seconds since midnight for a time.
    let seconds: Int?
    /// Digits after the decimal point, with trailing zeros removed for exact comparison.
    let fraction: String

    /// `YYYY`, `YYYY-MM` or `YYYY-MM-DD`.
    static func date(_ text: String) -> Self? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count),
              parts[0].count == 4,
              parts.dropFirst().allSatisfy({ $0.count == 2 }),
              let values = digits(parts),
              isValidDate(values) else {
            return nil
        }
        return Self(date: values, seconds: nil, fraction: "")
    }

    /// A FHIR `dateTime`: a partial date, or a full date with a time of day and a time zone.
    static func dateTime(_ text: String) -> Self? {
        guard let separator = text.firstIndex(of: "T") else {
            return date(text)
        }
        guard let day = date(String(text[..<separator])), day.date.count == 3 else {
            return nil
        }
        let rest = text[text.index(after: separator)...]
        guard let zoneStart = rest.firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }),
              let clock = time(String(rest[..<zoneStart])),
              let clockSeconds = clock.seconds,
              let offset = offset(String(rest[zoneStart...])) else {
            return nil
        }
        let days = daysSinceEpoch(year: day.date[0], month: day.date[1], day: day.date[2])
        return Self(date: day.date, seconds: days * 86_400 + clockSeconds - offset, fraction: clock.fraction)
    }

    /// `hh:mm:ss` with optional fractional seconds.
    static func time(_ text: String) -> Self? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0].count == 2, parts[1].count == 2,
              let clock = digits([parts[0], parts[1]]), clock[0] < 24, clock[1] < 60,
              let seconds = fractionalSeconds(parts[2]) else {
            return nil
        }
        return Self(date: [], seconds: clock[0] * 3_600 + clock[1] * 60 + seconds.whole, fraction: seconds.fraction)
    }

    private static func order<Value: Comparable>(_ left: Value, _ right: Value) -> ComparisonResult {
        left < right ? .orderedAscending : left > right ? .orderedDescending : .orderedSame
    }

    private static func digits(_ parts: [String]) -> [Int]? { // swiftlint:disable:this discouraged_optional_collection
        let values = parts.compactMap { part in part.allSatisfy(\.isASCIIDigit) ? Int(part) : nil }
        return values.count == parts.count ? values : nil
    }

    private static func fractionalSeconds(_ text: String) -> (whole: Int, fraction: String)? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), parts[0].count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }),
              let whole = Int(parts[0]), whole <= 60 else {
            return nil
        }
        let fraction = parts.dropFirst().first ?? ""
        let end = fraction.lastIndex(where: { $0 != "0" }).map { fraction.index(after: $0) } ?? fraction.startIndex
        return (whole, String(fraction[..<end]))
    }

    private static func offset(_ text: String) -> Int? {
        if text == "Z" {
            return 0
        }
        let sign = text.first == "-" ? -1 : 1
        let parts = text.dropFirst().split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard text.first == "+" || text.first == "-", parts.count == 2, parts.allSatisfy({ $0.count == 2 }),
              let values = digits(parts), values[1] < 60, values[0] * 60 + values[1] <= 14 * 60 else {
            return nil
        }
        return sign * (values[0] * 3_600 + values[1] * 60)
    }

    private static func isValidDate(_ values: [Int]) -> Bool {
        guard values[0] >= 1 else {
            return false
        }
        guard values.count > 1 else {
            return true
        }
        guard (1...12).contains(values[1]) else {
            return false
        }
        guard values.count > 2 else {
            return true
        }
        let leap = values[0].isMultiple(of: 4) && (!values[0].isMultiple(of: 100) || values[0].isMultiple(of: 400))
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...lengths[values[1] - 1]).contains(values[2])
    }

    /// Days from 1970-01-01 in the proleptic Gregorian calendar.
    private static func daysSinceEpoch(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// Compares two values of the same family. Values that agree down to the coarser precision of the two have no order.
    func compare(to other: Self) -> ComparisonResult? {
        if let seconds, let otherSeconds = other.seconds {
            return seconds == otherSeconds ? Self.order(fraction, other.fraction) : Self.order(seconds, otherSeconds)
        }
        for (left, right) in zip(date, other.date) where left != right {
            return Self.order(left, right)
        }
        return date.count == other.date.count && seconds == nil && other.seconds == nil ? .orderedSame : nil
    }
}


extension Character {
    fileprivate var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
