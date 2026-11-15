//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import ModelsR4
import Testing
@testable import TroveServer


struct FHIRRecordingProjectionTests {
    @Test
    func routeSelectionUsesLocationTimesRatherThanConversionTime() throws {
        let bytes = try Data(contentsOf: Self.fixtureURL())
        let graph = try ExchangeGraph(validating: bytes, kind: .active)
        let document = try #require(graph.bundle.entry?.compactMap { $0.resource?.get(if: DocumentReference.self) }.first)
        let bounds = try #require(try? FHIRRecordingProjection.routeBounds(document), "Route measurement bounds")
        #expect(bounds.0 == Date(timeIntervalSince1970: 1_787_005_800))
        try #require((try? FHIRPointSupportBoundary.validateExtensionLocations(in: bytes)) != nil, "Supported extension locations")
        let (_, resources) = try FHIRPointProjection.index(#require(graph.bundle.entry))
        try #require((try? FHIRPointSupportBoundary.validate(resources: resources)) != nil, "Supported resource references")
        let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "synthetic-shape-only")
        let output = try #require(event.outputs.first)
        #expect(event.outputs.count == 1 && output.value == .recording)
        #expect(output.effectiveAt == Date(timeIntervalSince1970: 1_787_005_800))
        #expect(output.effectiveEnd == Date(timeIntervalSince1970: 1_787_005_801))
        #expect(output.profile == FHIRRecordingProjection.profile)
        #expect(output.code == FHIRRecordingProjection.routeFormat)
    }

    @Test(arguments: ["url", "format", "source-type", "header", "empty", "timestamp"])
    func refusesUnselectableOrUnsupportedRecordings(corruption: String) throws {
        let bytes = try Self.mutated { document in
            var content = try #require(document["content"] as? [[String: Any]])
            var attachment = try #require(content[0]["attachment"] as? [String: Any])
            let encoded = try #require(attachment["data"] as? String)
            let decoded = try #require(Data(base64Encoded: encoded))
            var payload = try #require(String(data: decoded, encoding: .utf8))
            switch corruption {
            case "url": attachment["url"] = "https://outside.test/route.csv"
            case "format": content[0]["format"] = ["system": FHIRRecordingProjection.formatSystem, "code": "beat-interval-series"]
            case "source-type":
                document["extension"] = [
                    [
                        "url": "https://grovealliance.org/fhir/healthkit/StructureDefinition/healthkit-source-type",
                        "valueCode": "HKHeartbeatSeriesTypeIdentifier"
                    ]
                ]
            case "header": payload = payload.replacingOccurrences(of: "timestamp,", with: "other,")
            case "empty": payload = String(try #require(payload.split(separator: "\n").first)) + "\n"
            default: payload = payload.replacingOccurrences(of: "1787005800,", with: "NaN,")
            }
            attachment["data"] = Data(payload.utf8).base64EncodedString()
            content[0]["attachment"] = attachment
            document["content"] = content
        }
        #expect { try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "synthetic-shape-only") }
            throws: { ($0 as? ServerError)?.status.code == 422 }
    }
}


extension FHIRRecordingProjectionTests {
    static func fixtureURL() throws -> URL {
        try #require(Bundle.module.url(forResource: "HealthKitWorkoutRouteEvent", withExtension: "json"))
    }

    private static func mutated(_ change: (inout [String: Any]) throws -> Void) throws -> Data {
        var bundle = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL())) as? [String: Any])
        var entries = try #require(bundle["entry"] as? [[String: Any]])
        let index = try #require(entries.firstIndex { ($0["resource"] as? [String: Any])?["resourceType"] as? String == "DocumentReference" })
        var document = try #require(entries[index]["resource"] as? [String: Any])
        try change(&document)
        entries[index]["resource"] = document
        bundle["entry"] = entries
        return try JSONSerialization.data(withJSONObject: bundle)
    }
}
