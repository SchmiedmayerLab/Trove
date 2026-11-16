// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

#if canImport(HealthKit)

import Foundation
import HealthKit
import Testing
@testable import TroveHealthKit


struct HealthKitRecordConfigurationTests {
    private static let converter = Data("converter-build-1".utf8)

    /// A sample that was never saved has no source revision; its configuration must not depend on undefined writer facts.
    @Test
    func unsavedSampleStatesNoWriterFacts() throws {
        let sample = HKQuantitySample(
            type: HKQuantityType(.heartRate),
            quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: 72),
            start: Date(timeIntervalSince1970: 1_800_000_000),
            end: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try #require(sample.value(forKey: "sourceRevision") == nil)
        let configuration = try HealthKitAcquisition.recordConfiguration(for: sample, converter: Self.converter)
        let writer = try JSONEncoder().encode([String?]())
        #expect(configuration == (try JSONEncoder().encode([Self.converter, writer])))
        #expect(try HealthKitAcquisition.recordConfiguration(for: sample, converter: Self.converter) == configuration)
    }
}
#endif
