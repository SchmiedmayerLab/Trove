//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPITypes


/// The published rule is retained in the consent document; joining resolves the participant's exact end.
enum EnrollmentPeriodPresentation {
    static func markdown(_ period: EnrollmentPeriod, locale: String) throws -> String {
        try period.validate()
        guard period.duration != nil || period.end != nil else {
            return ""
        }
        let german: Bool
        switch locale {
        case "en", "en-US", "en-GB": german = false
        case "de", "de-DE": german = true
        default: throw ServerError.badRequest("Enrollment period translation is unavailable for this consent locale")
        }
        var lines = ["", "", german ? "## Teilnahmedauer" : "## Enrollment period"]
        if let duration = period.duration {
            let units = german ? [("Jahr", "Jahre"), ("Monat", "Monate"), ("Tag", "Tage")]
                : [("year", "years"), ("month", "months"), ("day", "days")]
            let text = zip([duration.year, duration.month, duration.day], units)
                .compactMap { value, unit in value.flatMap { $0 > 0 ? "\($0) \($0 == 1 ? unit.0 : unit.1)" : nil } }
                .joined(separator: ", ")
            lines.append((german ? "- Dauer ab Einschreibung: " : "- Duration from enrollment: ") + text)
            lines.append((german ? "- Kalender: gregorianisch; Zeitzone: " : "- Calendar: Gregorian; time zone: ") + period.timeZone)
        }
        if let end = period.end {
            try lines.append((german ? "- Ende vor (ausschließlich): " : "- Ends before (exclusive): ") + TroveDateTranscoder().encode(end))
        }
        if period.duration != nil, period.end != nil {
            lines.append(german ? "- Es gilt das frühere Ende." : "- The earlier end applies.")
        }
        lines.append(german
            ? "- Diese Regel gilt für neue Einschreibungen. Eine spätere Studienversion verlängert eine bestehende Teilnahme nicht."
            : "- This rule applies to new enrollments. A later study revision does not extend an existing enrollment.")
        return lines.joined(separator: "\n")
    }
}
