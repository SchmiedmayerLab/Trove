//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import OpenAPIRuntime


/// RFC 3339 at database microsecond precision. Opaque FHIR event bytes are unaffected.
public struct TroveDateTranscoder: DateTranscoder {
    public enum DateError: Error { case invalidDate }

    public init() {}

    public func encode(_ date: Date) throws -> String {
        let microseconds = try microseconds(date)
        var seconds = microseconds / 1_000_000
        var fraction = microseconds % 1_000_000
        if fraction < 0 {
            seconds -= 1
            fraction += 1_000_000
        }
        let whole = Date(timeIntervalSinceReferenceDate: Double(seconds)).formatted(.iso8601)
        guard whole.utf8.count == 20, whole.hasSuffix("Z"),
              let year = Int(whole.prefix(4)), (1...9999).contains(year) else { throw DateError.invalidDate }
        return String(whole.dropLast()) + String(format: ".%06lldZ", locale: Locale(identifier: "en_US_POSIX"), fraction)
    }

    public func decode(_ value: String) throws -> Date {
        guard (20...40).contains(value.utf8.count) else { throw DateError.invalidDate }
        let style = Date.ISO8601FormatStyle(includingFractionalSeconds: value.contains("."))
        let parsed = try style.parse(value)
        return Date(timeIntervalSinceReferenceDate: Double(try microseconds(parsed)) / 1_000_000)
    }

    private func microseconds(_ date: Date) throws -> Int64 {
        let value = (date.timeIntervalSinceReferenceDate * 1_000_000).rounded()
        guard value.isFinite, let result = Int64(exactly: value) else { throw DateError.invalidDate }
        return result
    }
}


extension Configuration {
    /// Compact API JSON with exact date boundaries; not for embedding raw JSON in HTML.
    public static var trove: Self {
        .init(dateTranscoder: TroveDateTranscoder(), jsonEncodingOptions: [.sortedKeys, .withoutEscapingSlashes])
    }
}
