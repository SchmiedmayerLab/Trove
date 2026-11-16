//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPITypes


/// Factual scope is part of the retained consent markdown and its digest/PDF, not a transient client-only label.
enum CollectionScopePresentation {
    static func markdown(requirements: [CollectionRequirement], locale: String) throws -> String {
        guard !requirements.isEmpty else {
            return ""
        }
        try CollectionRequirement.validate(requirements)
        let german: Bool
        switch locale {
        case "en", "en-US", "en-GB": german = false
        case "de", "de-DE": german = true
        default: throw ServerError.badRequest("Collection scope translation is unavailable for this consent locale")
        }
        var lines = ["", "", german ? "## Erfassung von Gesundheitsdaten" : "## Health data collection"]
        for requirement in requirements {
            let sleep = requirement.profile == CollectionObservationProfile.sleepStage.rawValue
            let workout = requirement.profile == CollectionObservationProfile.workout.rawValue
            let label = workout ? (german ? "- Trainingseinheiten" : "- Workouts")
                : sleep ? (german ? "- Schlafphasen" : "- Sleep stages") : (german ? "- Herzfrequenz" : "- Heart rate")
            lines.append(label)
            lines.append(german
                ? "- Die ursprüngliche HealthKit-Kennung (UUID) wird zusammen mit jeder Messung und ihrer Löschmeldung gespeichert."
                : "- The original HealthKit sample identifier (UUID) is retained with each measurement and its deletion notice.")
            lines += try bounds(requirement.measurementWindow, german: german)
            if workout {
                lines.append(requirement.includeWorkoutRoutes
                    ? (german ? "- Genaue Standortverläufe der Trainingseinheiten werden für diese Studie erfasst."
                        : "- Precise location routes for workouts are collected for this study.")
                    : (german ? "- Standortverläufe der Trainingseinheiten werden für diese Studie nicht erfasst."
                        : "- Workout location routes are not collected for this study."))
                lines.append(german
                    ? "- Trainingseinheiten werden mit allen Abschnitten und Statistiken vollständig erfasst, wenn sie den Erfassungszeitraum "
                        + "überlappen. Sie können davor beginnen oder danach enden."
                    : "- Workouts include all segments and statistics when the session overlaps the collection window. "
                        + "They may start before it or end after it.")
            }
            if sleep {
                lines.append(german
                    ? "- Schlafaufzeichnungen werden vollständig erfasst, wenn sie den Erfassungszeitraum überlappen. "
                        + "Sie können davor beginnen oder danach enden."
                    : "- Sleep records are collected in full when they overlap the collection window. They may start before it or end after it.")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func bounds(_ window: CollectionMeasurementWindow?, german: Bool) throws -> [String] {
        var lines: [String] = []
        switch window?.start {
        case .none:
            lines.append(german ? "- Messungen ab Annahme dieser Studienversion." : "- Measurements from acceptance of this study revision.")
        case .oldestSample:
            lines.append(german ? "- Alle verfügbaren früheren Messungen." : "- All available historical measurements.")
        case .absolute(let absolute):
            try lines.append((german ? "- Messungen ab: " : "- Measurements from: ") + instant(absolute.date))
        case .last(let relative):
            let values = relative.components
            let units = german ? [("Jahr", "Jahre"), ("Monat", "Monate"), ("Tag", "Tage")]
                : [("year", "years"), ("month", "months"), ("day", "days")]
            let offset = zip([values.year, values.month, values.day], units)
                .compactMap { value, unit in value.flatMap { $0 > 0 ? "\($0) \($0 == 1 ? unit.0 : unit.1)" : nil } }
                .joined(separator: ", ")
            lines.append((german ? "- Kalenderzeitraum vor Annahme: " : "- Calendar lookback before acceptance: ") + offset)
        }
        if let window {
            lines.append((german ? "- Kalender: gregorianisch; Zeitzone: " : "- Calendar: Gregorian; time zone: ") + window.timeZone)
        }
        if let end = window?.end {
            try lines.append((german ? "- Messungen vor (ausschließlich): " : "- Measurements before (exclusive): ") + instant(end))
        } else {
            lines.append(german ? "- Weitere Messungen während der Teilnahme." : "- Continuing measurements during enrollment.")
        }
        return lines
    }

    private static func instant(_ date: Date) throws -> String {
        try TroveDateTranscoder().encode(date)
    }
}
