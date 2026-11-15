//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPITypes
@testable import TroveServer


struct FHIRWorkoutProjectionTests {
    @Test(arguments: ["valid", "reference", "nested", "url", "extra"])
    func unmappedSDKValueHasOnlyItsTypedLeaf(corruption: String) throws {
        var value: [String: Any] = [
            "url": "https://grovealliance.org/fhir/healthkit/StructureDefinition/healthkit-unmapped-source-value", "valueString": "999"
        ]
        switch corruption {
        case "reference":
            value.removeValue(forKey: "valueString")
            value["valueReference"] = ["reference": "Patient/foreign"]
        case "nested": value["extension"] = [["url": "unexpected", "valueString": "hidden"]]
        case "url": value["url"] = "https://unexpected.test/extension"
        case "extra": value["unexpected"] = "hidden"
        default: break
        }
        let resource: [String: Any] = ["resourceType": "Observation", "valueCodeableConcept": ["extension": [value]]]
        let bytes = try JSONSerialization.data(withJSONObject: ["entry": [["resource": resource]]])
        if corruption == "valid" {
            try FHIRPointSupportBoundary.validateExtensionLocations(in: bytes)
        } else {
            #expect { try FHIRPointSupportBoundary.validateExtensionLocations(in: bytes) }
                throws: { ($0 as? ServerError)?.status.code == 422 }
        }
    }

    @Test
    func projectsTheWholeSessionAndAllNativeSegments() throws {
        let event = try FHIRPointProjection.project(validatedBytes: Self.bytes(), validatorIdentity: "synthetic-shape-only")
        #expect(event.outputs.count == 14)
        let sessions = event.outputs.filter { $0.profile == CollectionObservationProfile.workout.rawValue }
        let session = try #require(sessions.first)
        #expect(sessions.count == 1 && session.effectiveEnd?.timeIntervalSince(session.effectiveAt) == 3600)
        #expect(session.value == .coded(system: FHIRWorkoutProjection.activitySystem, code: "running"))
        let selections = try FHIRWorkoutProjection.collectionOutputs(event.outputs.map {
            .init(fullURL: $0.fullURL, profile: $0.profile, effectiveAt: $0.effectiveAt, effectiveEnd: $0.effectiveEnd)
        })
        #expect(selections.count == 14)
        #expect(selections.allSatisfy { $0.effectiveAt == session.effectiveAt && $0.effectiveEnd == session.effectiveEnd })
        #expect(event.outputs.contains { $0.effectiveAt != session.effectiveAt })
    }

    @Test(arguments: ["missing-members", "duplicate", "orphan", "outside", "no-end", "mixed", "segment-member", "reference-statistic"])
    func refusesIncompleteOrUnrelatedWorkoutContent(corruption: String) throws {
        let bytes = try Self.bytes { entries in
            let observations = entries.indices.filter { (entries[$0]["resource"] as? [String: Any])?["resourceType"] as? String == "Observation" }
            let parent = try #require(observations.first), child = try #require(observations.dropFirst().first)
            var session = try #require(entries[parent]["resource"] as? [String: Any])
            var segment = try #require(entries[child]["resource"] as? [String: Any])
            var members = try #require(session["hasMember"] as? [[String: Any]])
            switch corruption {
            case "missing-members": session.removeValue(forKey: "hasMember")
            case "duplicate": members.append(members[0]); session["hasMember"] = members
            case "orphan": members.removeLast(); session["hasMember"] = members
            case "outside": segment["effectivePeriod"] = ["start": "2026-08-05T00:00:00Z", "end": "2026-08-07T00:00:00Z"]
            case "no-end": segment["effectivePeriod"] = ["start": "2026-08-06T07:06:40Z"]
            case "mixed": segment["meta"] = ["profile": [CollectionObservationProfile.sleepStage.rawValue]]
            case "segment-member": segment["hasMember"] = [members[0]]
            default:
                session["component"] = [["code": ["text": "unexpected"], "valueReference": ["reference": "Patient/foreign"]]]
            }
            entries[parent]["resource"] = session
            entries[child]["resource"] = segment
        }
        #expect { try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "synthetic-shape-only") }
            throws: { ($0 as? ServerError)?.status.code == 422 }
    }
}


extension FHIRWorkoutProjectionTests {
    private static func bytes(_ mutate: (inout [[String: Any]]) throws -> Void = { _ in }) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "HealthKitWorkoutEvent", withExtension: "json"))
        var bundle = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try #require(bundle["entry"] as? [[String: Any]])
        try mutate(&entries)
        bundle["entry"] = entries
        return try JSONSerialization.data(withJSONObject: bundle, options: [.sortedKeys])
    }
}
