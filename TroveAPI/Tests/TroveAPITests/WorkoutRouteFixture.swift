//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

#if canImport(HealthKit)

import CoreLocation
import Foundation
import HealthKit
import ObjectiveC
import Testing


/// Test-only stored sample construction, adapted from Grove's StoredSampleFixtures.
/// HealthKit offers no public route or heartbeat-series initializer. Verify the private storage before using KVC,
/// and verify every public accessor afterwards so SDK changes fail the test explicitly.
enum WorkoutRouteFixture {
    static func sample(start: Date, end: Date, count: Int) throws -> HKWorkoutRoute {
        try sample(HKWorkoutRoute.self, sampleType: HKSeriesType.workoutRoute(), start: start, end: end, count: count)
    }

    static func heartbeatSeries(start: Date, end: Date, count: Int) throws -> HKHeartbeatSeriesSample {
        try sample(HKHeartbeatSeriesSample.self, sampleType: HKSeriesType.heartbeat(), start: start, end: end, count: count)
    }

    private static func sample<Sample: HKSeriesSample>(
        _ type: Sample.Type, sampleType: HKSeriesType, start: Date, end: Date, count: Int
    ) throws -> Sample {
        let route = try #require(class_createInstance(type, 0) as? Sample)
        let uuid = UUID()
        let source = try #require(class_createInstance(HKSource.self, 0) as? HKSource)
        for key in ["name", "bundleIdentifier"] {
            try #require(class_getInstanceVariable(HKSource.self, "_\(key)") != nil)
        }
        source.setValue("Route Writer", forKey: "name")
        source.setValue("org.trove.test.writer", forKey: "bundleIdentifier")
        try #require(source.name == "Route Writer" && source.bundleIdentifier == "org.trove.test.writer")
        let revision = HKSourceRevision(
            source: source,
            version: "1",
            productType: nil,
            operatingSystemVersion: .init(majorVersion: 27, minorVersion: 2, patchVersion: 0)
        )
        let values: [(String, Any)] = [
            ("UUID", uuid), ("sourceRevision", revision), ("sampleType", sampleType),
            ("startTimestamp", start.timeIntervalSinceReferenceDate), ("endTimestamp", end.timeIntervalSinceReferenceDate),
            (type == HKHeartbeatSeriesSample.self ? "numberOfDataPoints" : "count", count), ("metadata", [HKMetadataKeyTimeZone: "UTC"])
        ]
        for (key, _) in values {
            try #require(class_getInstanceVariable(type, "_\(key)") != nil, "Stored series fixture needs updated storage")
        }
        for (key, value) in values { route.setValue(value, forKey: key) }
        try #require(route.uuid == uuid && route.sourceRevision == revision && route.sampleType == sampleType)
        try #require(route.startDate == start && route.endDate == end && route.count == count)
        try #require(route.metadata?[HKMetadataKeyTimeZone] as? String == "UTC")
        return route
    }

    static func location(at date: Date) -> CLLocation {
        CLLocation(
            coordinate: .init(latitude: 37.4275, longitude: -122.1697),
            altitude: 30,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            timestamp: date
        )
    }
}

#endif
