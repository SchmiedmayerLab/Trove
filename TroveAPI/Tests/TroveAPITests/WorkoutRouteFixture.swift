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
/// HealthKit offers no public route initializer. Verify the private storage before using KVC,
/// and verify every public accessor afterwards so SDK changes fail the test explicitly.
enum WorkoutRouteFixture {
    static func sample(start: Date, end: Date, count: Int) throws -> HKWorkoutRoute {
        let route = try #require(class_createInstance(HKWorkoutRoute.self, 0) as? HKWorkoutRoute)
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
            ("UUID", uuid), ("sourceRevision", revision), ("sampleType", HKSeriesType.workoutRoute()),
            ("startTimestamp", start.timeIntervalSinceReferenceDate), ("endTimestamp", end.timeIntervalSinceReferenceDate),
            ("count", count), ("metadata", [HKMetadataKeyTimeZone: "UTC"])
        ]
        for (key, _) in values {
            try #require(class_getInstanceVariable(HKWorkoutRoute.self, "_\(key)") != nil, "Stored route fixture needs updated storage")
        }
        for (key, value) in values { route.setValue(value, forKey: key) }
        try #require(route.uuid == uuid && route.sourceRevision == revision && route.sampleType == HKSeriesType.workoutRoute())
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
