// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT


/// Explicit translations for measurements without a corresponding native HealthKit title.
enum ProviderCollectionPresentation {
    private static let titles: [String: (english: String, german: String)] = [
        "distance": ("Distance", "Entfernung"),
        "speed": ("Speed", "Geschwindigkeit"),
        "power": ("Power", "Leistung"),
        "workout-effort-score": ("Workout effort score", "Anstrengungswert des Trainings"),
        "body-water-mass": ("Body water mass", "Körperwassermasse"),
        "bone-mass": ("Bone mass", "Knochenmasse"),
        "heart-rate-variability-rmssd": ("Heart rate variability (RMSSD)", "Herzfrequenzvariabilität (RMSSD)"),
        "oxygen-saturation-daily-average": ("Daily average oxygen saturation", "Tagesmittel der Sauerstoffsättigung"),
        "respiratory-rate-average": ("Average respiratory rate", "Mittlere Atemfrequenz"),
        "deep-sleep-duration": ("Deep sleep duration", "Tiefschlafdauer"),
        "light-sleep-duration": ("Light sleep duration", "Dauer des leichten Schlafs"),
        "rem-sleep-duration": ("REM sleep duration", "REM-Schlafdauer"),
        "sleep-awake-duration": ("Awake time during sleep session", "Wachzeit während der Schlafaufzeichnung"),
        "sleep-duration": ("Sleep duration", "Schlafdauer"),
        "sleep-heart-rate": ("Average heart rate during sleep", "Mittlere Herzfrequenz während des Schlafs"),
        "resting-heart-rate-daily-average": ("Daily average resting heart rate (Google Health)", "Tagesmittel der Ruheherzfrequenz (Google Health)"),
        "oura-cardiovascular-age": ("Estimated cardiovascular age (Oura)", "Geschätztes Herz-Kreislauf-Alter (Oura)"),
        "oura-readiness-score": ("Readiness score (Oura)", "Tagesformwert (Oura)"),
        "body-fat-mass": ("Body fat mass (Withings)", "Körperfettmasse (Withings)"),
        "extracellular-water-mass": ("Extracellular water mass (Withings)", "Extrazelluläre Wassermasse (Withings)"),
        "intracellular-water-mass": ("Intracellular water mass (Withings)", "Intrazelluläre Wassermasse (Withings)"),
        "muscle-mass": ("Muscle mass (Withings)", "Muskelmasse (Withings)"),
        "corrected-qt-interval": ("Corrected QT interval (Withings)", "Korrigiertes QT-Intervall (Withings)"),
        "pr-interval": ("PR interval (Withings)", "PR-Intervall (Withings)"),
        "qrs-duration": ("QRS duration (Withings)", "QRS-Dauer (Withings)"),
        "qt-interval": ("QT interval (Withings)", "QT-Intervall (Withings)"),
        "withings-atrial-fibrillation-notification-ecg": (
            "ECG atrial fibrillation screening notification (Withings)",
            "EKG-Screening-Mitteilung zu Vorhofflimmern (Withings)"
        ),
        "withings-atrial-fibrillation-notification-ppg": (
            "PPG atrial fibrillation screening notification (Withings)",
            "PPG-Screening-Mitteilung zu Vorhofflimmern (Withings)"
        ),
        "withings-nerve-health-score": ("Nerve health score (Withings)", "Nervengesundheitswert (Withings)"),
        "withings-pulse-wave-velocity": ("Estimated pulse wave velocity (Withings)", "Geschätzte Pulswellengeschwindigkeit (Withings)"),
        "withings-vascular-age": ("Estimated vascular age (Withings)", "Geschätztes Gefäßalter (Withings)"),
        "withings-visceral-fat-index": ("Visceral fat index (Withings)", "Index des viszeralen Fetts (Withings)")
    ]

    static func title(measurementID: String, german: Bool) -> String? {
        guard let title = titles[measurementID] else {
            return nil
        }
        return german ? title.german : title.english
    }
}
