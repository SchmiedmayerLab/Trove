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


extension SensorKitCollectionSource {
    var recordingSensor: (any AnySensor)? {
        switch self {
        case .electrocardiogram: Sensor.ecg
        case .deviceUsage: Sensor.deviceUsage
        case .wristTemperature: Sensor.wristTemperature
        case .photoplethysmogram: Sensor.ppg
        case .accelerometer: Sensor.accelerometer
        case .ambientLight: Sensor.ambientLight
        case .ambientPressure: Sensor.ambientPressure
        case .heartRate: Sensor.heartRate
        case .pedometer: Sensor.pedometer
        case .headphoneMotion, .headphoneSettings: headphoneSensor
        default: nil
        }
    }

    /// The headphone sensors exist only from the iOS 27 SDK on; earlier SDKs build without them.
    private var headphoneSensor: (any AnySensor)? {
        #if compiler(>=6.4)
        if #available(iOS 27, *) {
            switch self {
            case .headphoneMotion: return Sensor.headphoneMotion
            case .headphoneSettings: return Sensor.headphoneSettings
            default: return nil
            }
        }
        #endif
        return nil
    }

    func catchUpRecording(
        acquisition: SensorKitAcquisition, localID: UUID, sensorKit: GroveSensorKit.SensorKit, application: ApplicationDevice, host: HostDevice
    ) async throws -> Bool {
        switch self {
        case .accelerometer:
            try await acquisition.catchUpTabular(Sensor.accelerometer, localID: localID, sensorKit: sensorKit, application: application, host: host)
        case .ambientLight:
            try await acquisition.catchUpTabular(Sensor.ambientLight, localID: localID, sensorKit: sensorKit, application: application, host: host)
        case .ambientPressure:
            try await acquisition.catchUpTabular(Sensor.ambientPressure, localID: localID, sensorKit: sensorKit, application: application, host: host)
        case .heartRate:
            try await acquisition.catchUpTabular(Sensor.heartRate, localID: localID, sensorKit: sensorKit, application: application, host: host)
        case .pedometer:
            try await acquisition.catchUpTabular(Sensor.pedometer, localID: localID, sensorKit: sensorKit, application: application, host: host)
        case .headphoneMotion, .headphoneSettings:
            try await catchUpHeadphones(acquisition: acquisition, localID: localID, sensorKit: sensorKit, application: application, host: host)
        default:
            try await catchUpHybrid(acquisition: acquisition, localID: localID, sensorKit: sensorKit, application: application, host: host)
        }
    }

    private func catchUpHeadphones(
        acquisition: SensorKitAcquisition, localID: UUID, sensorKit: GroveSensorKit.SensorKit, application: ApplicationDevice, host: HostDevice
    ) async throws -> Bool {
        #if compiler(>=6.4)
        if #available(iOS 27, *) {
            if self == .headphoneMotion {
                return try await acquisition.catchUpTabular(
                    Sensor.headphoneMotion, localID: localID, sensorKit: sensorKit, application: application, host: host
                )
            }
            return try await acquisition.catchUpTabular(
                Sensor.headphoneSettings, localID: localID, sensorKit: sensorKit, application: application, host: host
            )
        }
        #endif
        throw SensorKitAcquisition.AcquisitionError.invalidBatch
    }

    private func catchUpHybrid(
        acquisition: SensorKitAcquisition, localID: UUID, sensorKit: GroveSensorKit.SensorKit, application: ApplicationDevice, host: HostDevice
    ) async throws -> Bool {
        switch self {
        case .electrocardiogram:
            try await acquisition.catchUpElectrocardiogram(localID: localID, sensorKit: sensorKit, application: application, host: host)
        case .deviceUsage:
            try await acquisition.catchUpDeviceUsage(localID: localID, sensorKit: sensorKit, application: application, host: host)
        case .wristTemperature:
            try await acquisition.catchUpWristTemperature(localID: localID, sensorKit: sensorKit, application: application, host: host)
        case .photoplethysmogram:
            try await acquisition.catchUpPhotoplethysmogram(localID: localID, sensorKit: sensorKit, application: application, host: host)
        default: throw SensorKitAcquisition.AcquisitionError.invalidBatch
        }
    }
}

#endif
