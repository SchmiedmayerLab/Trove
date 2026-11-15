// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

#if canImport(HealthKit) && !os(watchOS)

import Foundation
import HealthKit
import ObjectiveC
import Testing


/// Stored source construction adapted from Grove's fixture, checking storage and public accessors against SDK changes.
enum ClinicalDocumentFixture {
    static let bytes = Data((
        "{\"resourceType\":\"Observation\",\"status\":\"final\",\"effectiveDateTime\":\"2000-01-01T00:00:00Z\","
            + "\"valueQuantity\":{\"value\":1.234567890123456789}}"
    ).utf8)

    static func sample(type: HKClinicalType, start: Date, end: Date, version: String = "4.0.1") throws -> HKClinicalRecord {
        let source = try #require(class_createInstance(HKSource.self, 0) as? HKSource)
        try set(source, ["name": "Document Writer", "bundleIdentifier": "org.trove.test.document"])
        let revision = HKSourceRevision(source: source, version: "1")
        let sample = try #require(class_createInstance(HKClinicalRecord.self, 0) as? HKClinicalRecord)
        let uuid = UUID()
        try set(sample, [
            "UUID": uuid, "sourceRevision": revision, "sampleType": type,
            "startTimestamp": start.timeIntervalSinceReferenceDate, "endTimestamp": end.timeIntervalSinceReferenceDate,
            "metadata": [HKMetadataKeyTimeZone: "UTC"]
        ])
        let resource = try #require(class_createInstance(HKFHIRResource.self, 0) as? HKFHIRResource)
        let fhirVersion = try HKFHIRVersion(fromVersionString: version)
        try set(resource, ["data": bytes, "FHIRVersion": fhirVersion])
        try set(sample, ["FHIRResource": resource])
        try #require(sample.uuid == uuid && sample.sampleType == type && sample.startDate == start && sample.endDate == end)
        try #require(sample.fhirResource?.data == bytes && sample.fhirResource?.fhirVersion == fhirVersion)
        try #require(sample.sourceRevision == revision && source.bundleIdentifier == "org.trove.test.document")
        return sample
    }

    private static func set(_ object: NSObject, _ values: [String: Any]) throws {
        for key in values.keys {
            try #require(class_getInstanceVariable(type(of: object), "_\(key)") != nil, "Stored document fixture needs updated SDK storage")
        }
        for (key, value) in values { object.setValue(value, forKey: key) }
    }
}

#endif
