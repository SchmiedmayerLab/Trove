// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import TroveAPIServer


/// Rules for linking the exact response as this occurrence's completed output. They run before the pair rules and the validator.
enum TaskResultEvidence {
    private struct Instant: Comparable {
        let second: Date
        let fraction: String

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.second == rhs.second ? lhs.fraction < rhs.fraction : lhs.second < rhs.second
        }
    }

    static let tooLarge = ServerError(
        status: .contentTooLarge, title: "Task Response Too Large", detail: "The response exceeds the admission size limit"
    )

    /// Server times differ between replicas and clients by a bounded amount; an authored time further ahead is refused.
    static let clockTolerance: TimeInterval = 300

    /// Checks the subject and the authored time, and returns the authored time as submitted.
    /// - Parameter now: When given, the authored time must not lie more than ``clockTolerance`` after it.
    @discardableResult
    static func check(
        _ response: Data, opens: Date, cutoff: Date?, subjectSystem: String, subjectValue: String, now: Date? = nil
    ) throws -> String {
        let invalid = ServerError(
            status: .unprocessableContent,
            title: "Invalid task output",
            detail: "The response subject, authored time or modifier extensions do not match"
        )
        // A modifier extension changes the meaning of the response; no consumer of task results understands one.
        guard let resource = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any], resource["modifierExtension"] == nil,
            let subject = resource["subject"] as? [String: Any], Set(subject.keys) == ["type", "identifier"],
            subject["type"] as? String == "Patient",
            let identifier = subject["identifier"] as? [String: String], identifier == ["system": subjectSystem, "value": subjectValue],
            let authored = resource["authored"] as? String,
            let recorded = instant(authored),
            let start = try instant(TroveDateTranscoder().encode(opens)), start <= recorded
        else {
            throw invalid
        }
        if let cutoff {
            guard let end = try instant(TroveDateTranscoder().encode(cutoff)), recorded < end else { throw invalid }
        }
        if let now {
            guard let latest = try instant(TroveDateTranscoder().encode(now.addingTimeInterval(clockTolerance))), recorded <= latest else {
                throw invalid
            }
        }
        return authored
    }

    private static func instant(_ value: String) -> Instant? {
        let date = /([0-9]{4})-([0-9]{2})-([0-9]{2})/
        let time = /T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])/
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .gmt
        guard let day = value.prefix(10).wholeMatch(of: date),
              let year = Int(day.1), year > 0, let month = Int(day.2), let number = Int(day.3),
              let clock = value.dropFirst(10).wholeMatch(of: time),
              DateComponents(year: year, month: month, day: number).isValidDate(in: calendar),
              let second = try? Date.ISO8601FormatStyle().parse(String(value.prefix(19)) + clock.3) else {
            return nil
        }
        let digits = clock.2?.dropFirst() ?? ""
        let fraction = digits.lastIndex(where: { $0 != "0" }).map { String(digits[...$0]) } ?? ""
        return .init(second: second, fraction: fraction)
    }
}
