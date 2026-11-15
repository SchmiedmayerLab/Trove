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
            lines.append("- " + (try displayName(requirement.profile, german: german, sourceTypeIdentifier: requirement.sourceTypeIdentifier)))
            if requirement.sourceKind == .participantApp,
               CollectionObservationProfile(rawValue: requirement.profile)?.nativeSources.isEmpty == false || workout {
                lines.append(german
                    ? "- Die ursprüngliche HealthKit-Kennung (UUID) wird zusammen mit jeder Messung und ihrer Löschmeldung gespeichert."
                    : "- The original HealthKit sample identifier (UUID) is retained with each measurement and its deletion notice.")
            }
            if requirement.profile == CollectionObservationProfile.food.rawValue {
                lines.append(german
                    ? "- Einträge zu Mahlzeiten enthalten Verweise auf ihre Nährstoffaufzeichnungen. "
                        + "Nährstoffmessungen werden für diese Studie nur mit separat ausgewählter Berechtigung erfasst."
                    : "- Food entries retain links to their nutrient records. "
                        + "Nutrient measurements are collected for this study only when separately selected and authorized.")
            }
            lines += try bounds(requirement.measurementWindow, german: german, timeBasis: requirement.timeBasis ?? .measurementTime)
            if let disclosure = documentDisclosure(requirement.timeBasis, german: german) {
                lines.append(disclosure)
                continue
            }
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
            if !workout, let profile = CollectionObservationProfile(rawValue: requirement.profile), profile.permitsEffectiveTime(hasEnd: true) {
                lines.append(wholeRecordOverlap(german: german, sleep: sleep))
            }
        }
        return lines.joined(separator: "\n")
    }

    static func displayName(_ rawProfile: String, german: Bool, sourceTypeIdentifier: String? = nil) throws -> String {
        guard let profile = CollectionObservationProfile(rawValue: rawProfile) else {
            throw ServerError.badRequest("Unsupported collection profile")
        }
        return switch profile {
        case .heartRate: german ? "Herzfrequenz" : "Heart rate"
        case .bodyWeight: german ? "Körpergewicht" : "Body weight"
        case .sleepStage: german ? "Schlafphasen" : "Sleep stages"
        case .workout: german ? "Trainingseinheiten" : "Workouts"
        case .onWrist: german ? "Tragezustand der Uhr" : "Watch wear state"
        default:
            if let title = profile.localizedNativeTitle(language: german ? "de" : "en", sourceTypeIdentifier: sourceTypeIdentifier) {
                title
            } else if let title = SensorKitCollectionPresentation.title(
                profile: profile, sourceTypeIdentifier: sourceTypeIdentifier, german: german
            ) {
                title
            } else if let id = profile.measurement?.id, let title = ProviderCollectionPresentation.title(measurementID: id, german: german) {
                title
            } else {
                throw ServerError.badRequest("Collection scope translation is unavailable for this measurement")
            }
        }
    }

    private static func wholeRecordOverlap(german: Bool, sleep: Bool) -> String {
        if sleep {
            return german
                ? "- Schlafaufzeichnungen werden vollständig erfasst, wenn sie den Erfassungszeitraum überlappen. "
                    + "Sie können davor beginnen oder danach enden."
                : "- Sleep records are collected in full when they overlap the collection window. They may start before it or end after it."
        }
        return german
            ? "- Zeitlich ausgedehnte Aufzeichnungen werden vollständig erfasst, wenn sie den Erfassungszeitraum überlappen. "
                + "Sie können davor beginnen oder danach enden."
            : "- Interval records are collected in full when they overlap the collection window. They may start before it or end after it."
    }

    private static func documentDisclosure(_ basis: CollectionTimeBasis?, german: Bool) -> String? {
        switch basis {
        case .clinicalRecordDownload:
            german
                ? "- Der Zeitraum bezieht sich darauf, wann HealthKit das Dokument auf dieses Gerät heruntergeladen hat. "
                    + "Das vollständige Originaldokument wird erfasst und kann Behandlungen außerhalb dieses Zeitraums beschreiben."
                : "- The window refers to when HealthKit downloaded the document to this device. "
                    + "The complete original document is collected and may describe care outside this window."
        case .cdaSourceDocumentPeriod:
            german
                ? "- Der Zeitraum bezieht sich auf die vom Ersteller zugewiesenen Dokumentdaten, nicht auf Behandlungs- oder Downloaddaten. "
                    + "Das vollständige CDA-Originaldokument wird nach der separaten Dokumentfreigabe erfasst."
                : "- The window refers to document dates assigned by the creator, not care or download dates. "
                    + "The complete original CDA document is collected after its separate document authorization."
        default: nil
        }
    }

    private static func bounds(
        _ window: CollectionMeasurementWindow?, german: Bool, timeBasis: CollectionTimeBasis
    ) throws -> [String] {
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
        if timeBasis != .measurementTime {
            return lines.map {
                $0.replacingOccurrences(of: german ? "Messungen" : "Measurements", with: german ? "Dokumentdaten" : "Source document dates")
                    .replacingOccurrences(of: "measurements", with: "source document dates")
            }
        }
        return lines
    }

    private static func instant(_ date: Date) throws -> String {
        try TroveDateTranscoder().encode(date)
    }
}
