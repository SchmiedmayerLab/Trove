// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import GroveFHIRContract
import GroveSensorKitFHIR
import TroveAPITypes


/// Collection labels describe the sensor output, independent of the catalog's identifier spelling.
enum SensorKitCollectionPresentation {
    static func title(profile: CollectionObservationProfile, sourceTypeIdentifier: String?, german: Bool) -> String? {
        let sources = profile.sensorKitSources
        let source = sourceTypeIdentifier.flatMap { identifier in sources.first { $0.sourceToken == identifier } }
            ?? (sources.count == 1 ? sources.first : nil)
        guard let source else {
            return nil
        }
        if profile.rawValue == SensorKitContract.recordingDocumentProfile, source.recordingFormats.count == 1 {
            return recordingTitle(source, german: german)
        }
        guard let observation = source.observation else {
            return nil
        }
        return observationTitle(observation.contract, german: german)
    }

    private static func observationTitle(_ contract: SensorKitStructuredContract, german: Bool) -> String? {
        switch contract {
        case .onWrist: german ? "Tragezustand der Uhr" : "Watch wear state"
        case .visit: german ? "Aufenthalte an Orten" : "Visits to locations"
        case .messagesUsage: german ? "Nutzung von Nachrichtendiensten" : "Messages usage"
        case .phoneUsage: german ? "Telefonnutzung" : "Phone usage"
        case .sleepSession: german ? "Schlafepisoden" : "Sleep sessions"
        default: hybridTitle(contract, german: german)
        }
    }

    /// Summaries that are retained together with their original recording.
    private static func hybridTitle(_ contract: SensorKitStructuredContract, german: Bool) -> String? {
        switch contract {
        case .electrocardiogram: german ? "Elektrokardiogramm" : "Electrocardiogram"
        case .deviceUsage: german ? "Zusammenfassung der Gerätenutzung" : "Device usage summary"
        case .wristTemperature: german ? "Temperatur am Handgelenk" : "Wrist temperature"
        case .accelerometer: german ? "Zusammenfassung der Beschleunigung" : "Acceleration summary"
        case .ppg: german ? "Zusammenfassung des Photoplethysmogramms" : "Photoplethysmogram summary"
        default: nil
        }
    }

    private static func recordingTitle(_ source: SensorKitOutputDefinition, german: Bool) -> String? {
        switch source.observation?.contract {
        case .electrocardiogram:
            german ? "Originalaufzeichnung des Elektrokardiogramms" : "Original electrocardiogram recording"
        case .deviceUsage:
            german ? "Originalbericht der Gerätenutzung" : "Original device usage report"
        default:
            recordingTitle(source.recordingFormats[0], german: german)
        }
    }

    private static func recordingTitle(_ format: RegisteredRecordingFormat, german: Bool) -> String? {
        switch format {
        case .wristTemperatureSamples: german ? "Originalaufzeichnung der Handgelenktemperatur" : "Original wrist temperature recording"
        case .photoplethysmogramSamples: german ? "Originalaufzeichnung des Photoplethysmogramms" : "Original photoplethysmogram recording"
        case .triaxialAccelerationSamples: german ? "Originalaufzeichnung der Beschleunigung" : "Original acceleration recording"
        case .ambientLightSamples: german ? "Originalaufzeichnung des Umgebungslichts" : "Original ambient light recording"
        case .ambientPressureSamples: german ? "Originalaufzeichnung des Umgebungsdrucks" : "Original ambient pressure recording"
        case .heartRateSamples: german ? "Originalaufzeichnung der Herzfrequenz" : "Original heart rate recording"
        case .pedometerSamples: german ? "Originalaufzeichnung des Schrittzählers" : "Original pedometer recording"
        case .deviceMotionSamples: german ? "Originalaufzeichnung der Kopfhörerbewegung" : "Original headphone motion recording"
        case .headphoneSettingsSamples: german ? "Originalaufzeichnung der Kopfhörereinstellungen" : "Original headphone settings recording"
        default: nil
        }
    }
}
