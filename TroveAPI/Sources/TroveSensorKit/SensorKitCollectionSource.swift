//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

#if os(iOS)

import Foundation
import GroveFHIRContract
import GroveSensorKit
import GroveSensorKitFHIR
import SensorKit
import TroveAPIClient


/// Native SensorKit adapters implemented by this client; guide inventory alone never enables a source.
public enum SensorKitCollectionSource: String, CaseIterable, Hashable, Sendable {
    case onWrist
    case visits
    case messagesUsage
    case phoneUsage
    case sleepSessions
    case accelerometer
    case electrocardiogram
    case deviceUsage
    case wristTemperature
    case ambientLight
    case ambientPressure
    case heartRate
    case pedometer
    case headphoneMotion
    case headphoneSettings
    case photoplethysmogram

    public var sensor: (any AnySensor)? {
        switch self {
        case .onWrist: return Sensor.onWrist
        case .visits: return Sensor.visits
        case .messagesUsage: return Sensor.messagesUsage
        case .phoneUsage: return Sensor.phoneUsage
        case .sleepSessions:
            if #available(iOS 26, *) {
                return Sensor.sleepSessions
            }
            return nil
        default: return recordingSensor
        }
    }

    public var catalogEntry: SensorKitCatalogEntry? {
        if let sensor {
            return SensorKitCatalog.current.entry(for: sensor)
        }
        // The accepted source scope remains visible when this OS cannot instantiate its sensor.
        // Application configuration can then report an unavailable adapter instead of hiding the request.
        let format: RegisteredRecordingFormat
        switch self {
        case .headphoneMotion: format = .deviceMotionSamples
        case .headphoneSettings: format = .headphoneSettingsSamples
        default: return nil
        }
        let candidates = SensorKitCatalog.current.entries.filter { $0.soleRawFormat == format }
        return candidates.count == 1 ? candidates.first : nil
    }

    public func isPermitted(by snapshot: ParticipantCollectionSnapshot) -> Bool {
        guard let entry = catalogEntry, let profiles = try? SensorKitAcquisition.requiredProfiles(for: entry) else {
            return false
        }
        return profiles.allSatisfy { snapshot.permitsAcquisition(of: $0, sourceTypeIdentifier: entry.sourceToken) }
    }

    /// Performs one bounded capture pass with the shared journal coordinator.
    public func catchUp(
        acquisition: SensorKitAcquisition,
        localID: UUID,
        sensorKit: GroveSensorKit.SensorKit,
        application: ApplicationDevice,
        host: HostDevice
    ) async throws -> Bool {
        switch self {
        case .onWrist:
            try await acquisition.catchUpOnWrist(localID: localID, sensorKit: sensorKit, application: application, host: host)
        case .visits:
            try await acquisition.catchUpVisits(localID: localID, sensorKit: sensorKit, application: application, host: host)
        case .messagesUsage:
            try await acquisition.catchUpMessagesUsage(localID: localID, sensorKit: sensorKit, application: application, host: host)
        case .phoneUsage:
            try await acquisition.catchUpPhoneUsage(localID: localID, sensorKit: sensorKit, application: application, host: host)
        case .sleepSessions:
            if #available(iOS 26, *) {
                try await acquisition.catchUpSleepSessions(localID: localID, sensorKit: sensorKit, application: application, host: host)
            } else {
                throw SensorKitAcquisition.AcquisitionError.invalidBatch
            }
        default:
            try await catchUpRecording(acquisition: acquisition, localID: localID, sensorKit: sensorKit, application: application, host: host)
        }
    }
}

#endif
