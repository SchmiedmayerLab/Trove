// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

#if canImport(HealthKit)

import Foundation
import HealthKit
import ObjectiveC
import Testing


/// TEST-ONLY. A stored ECG, adapted from Grove's fixture. HealthKit keeps the voltage count, sampling frequency and
/// classification where key-value coding cannot reach them, so this subclass answers them from an attached reading.
final class ElectrocardiogramFixture: HKElectrocardiogram, @unchecked Sendable {
    struct Reading {
        var symptomsStatus: SymptomsStatus
        var numberOfVoltageMeasurements: Int
        var averageHeartRate: HKQuantity?
        var samplingFrequency: HKQuantity?
    }

    nonisolated(unsafe) private static var readingKey: UInt8 = 0

    override var classification: Classification { .sinusRhythm }
    override var symptomsStatus: SymptomsStatus { reading.symptomsStatus }
    override var numberOfVoltageMeasurements: Int { reading.numberOfVoltageMeasurements }
    override var averageHeartRate: HKQuantity? { reading.averageHeartRate }
    override var samplingFrequency: HKQuantity? { reading.samplingFrequency }

    private var reading: Reading {
        guard let reading = objc_getAssociatedObject(self, &Self.readingKey) as? Reading else {
            preconditionFailure("A stored ECG states its reading when it is built")
        }
        return reading
    }

    /// A stored ECG over `start...end` with `millivolts` sampled at 500 Hz from its start, and its voltages.
    static func make(
        start: Date, end: Date, millivolts: [Double] = [0.125, 0.25, -0.125, 0], symptoms: Bool = false
    ) throws -> (ecg: HKElectrocardiogram, voltages: [HKElectrocardiogram.VoltageMeasurement]) {
        let ecg = try #require(class_createInstance(ElectrocardiogramFixture.self, 0) as? ElectrocardiogramFixture)
        let source = try #require(class_createInstance(HKSource.self, 0) as? HKSource)
        try set(source, ["name": "ECG Writer", "bundleIdentifier": "org.trove.test.ecg"])
        let revision = HKSourceRevision(
            source: source, version: "1", productType: nil, operatingSystemVersion: .init(majorVersion: 27, minorVersion: 2, patchVersion: 0)
        )
        let uuid = UUID()
        try set(ecg, [
            "UUID": uuid, "sourceRevision": revision, "sampleType": HKObjectType.electrocardiogramType(),
            "startTimestamp": start.timeIntervalSinceReferenceDate, "endTimestamp": end.timeIntervalSinceReferenceDate,
            "metadata": [HKMetadataKeyTimeZone: "UTC", HKMetadataKeyAppleECGAlgorithmVersion: 2]
        ])
        let reading = Reading(
            symptomsStatus: symptoms ? .present : .none,
            numberOfVoltageMeasurements: millivolts.count,
            averageHeartRate: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: 72),
            samplingFrequency: HKQuantity(unit: .hertz(), doubleValue: 500)
        )
        objc_setAssociatedObject(ecg, &readingKey, reading, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        try #require(ecg.uuid == uuid && ecg.startDate == start && ecg.endDate == end && ecg.sourceRevision == revision)
        let voltages = try millivolts.enumerated().map { index, value in
            let instance = class_createInstance(HKElectrocardiogram.VoltageMeasurement.self, 0)
            let measurement = try #require(instance as? HKElectrocardiogram.VoltageMeasurement)
            let offset = Double(index) / 500
            try set(measurement, [
                "timeSinceSampleStart": offset, "leadIVoltage": HKQuantity(unit: .voltUnit(with: .milli), doubleValue: value)
            ])
            try #require(measurement.timeSinceSampleStart == offset && measurement.quantity(for: .appleWatchSimilarToLeadI) != nil)
            return measurement
        }
        return (ecg, voltages)
    }

    private static func set(_ object: NSObject, _ values: [String: Any]) throws {
        for key in values.keys {
            try #require(class_getInstanceVariable(type(of: object), "_\(key)") != nil, "Stored ECG fixture needs updated SDK storage")
        }
        for (key, value) in values { object.setValue(value, forKey: key) }
    }
}

#endif
