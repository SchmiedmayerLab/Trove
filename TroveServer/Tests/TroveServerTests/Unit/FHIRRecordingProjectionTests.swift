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

    @Test("A recording's sole document states its writer revision like an Observation")
    func admitsTheWriterRevisionPairOnTheRecordingDocument() throws {
        let pair = try Self.goldenWriterRevision()
        let bytes = try Self.mutated { document in
            document["identifier"] = try #require(document["identifier"] as? [Any]) + [pair.identifier]
            document["extension"] = (document["extension"] as? [Any] ?? []) + [pair.version]
        }
        let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "synthetic-shape-only")
        let output = try #require(event.outputs.first)
        #expect(event.outputs.count == 1 && output.value == .recording)
        #expect(output.writerIdentifier?.system == pair.identifier["system"] as? String)
        #expect(output.writerIdentifier?.value == pair.identifier["value"] as? String)
        #expect(output.writerVersion == pair.version["valueString"] as? String)
        let revision = try ClinicalRecordRevision(event)
        #expect(revision.writer == output.writerIdentifier && revision.version == output.writerVersion)
    }

    @Test(arguments: ["identifier-only", "version-only", "two-identifiers", "two-versions", "non-canonical-version"])
    func refusesAnIncompleteOrNonCanonicalWriterRevision(corruption: String) throws {
        let pair = try Self.goldenWriterRevision()
        let bytes = try Self.mutated { document in
            var identifiers = try #require(document["identifier"] as? [Any])
            var extensions = document["extension"] as? [Any] ?? []
            var version = pair.version
            var secondIdentifier = pair.identifier
            secondIdentifier["value"] = "v0:test:1:" + String(repeating: "A", count: 43)
            switch corruption {
            case "identifier-only": identifiers.append(pair.identifier)
            case "version-only": extensions.append(version)
            case "two-identifiers": identifiers += [pair.identifier, secondIdentifier]; extensions.append(version)
            case "two-versions": identifiers.append(pair.identifier); extensions += [version, version]
            default:
                version["valueString"] = "03"
                identifiers.append(pair.identifier)
                extensions.append(version)
            }
            document["identifier"] = identifiers
            document["extension"] = extensions
        }
        #expect { try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "synthetic-shape-only") }
            throws: { ($0 as? ServerError)?.status.code == 422 }
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

    /// The writer-record identity and its version as Grove states them on a heartbeat series' primary document.
    private static func goldenWriterRevision() throws -> (identifier: [String: Any], version: [String: Any]) {
        let url = try #require(Bundle.module.url(forResource: "HealthKitHeartbeatSeriesWriterRecordEvent", withExtension: "json"))
        let bundle = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entries = try #require(bundle["entry"] as? [[String: Any]])
        let document = try #require(entries.lazy.compactMap { $0["resource"] as? [String: Any] }.first {
            $0["resourceType"] as? String == "DocumentReference"
        })
        let identifiers = try #require(document["identifier"] as? [[String: Any]])
        let writer = try #require(identifiers.first { identifier in
            ((identifier["type"] as? [String: Any])?["coding"] as? [[String: Any]])?.contains { $0["code"] as? String == "writer-record" } == true
        })
        let extensions = try #require(document["extension"] as? [[String: Any]])
        let version = try #require(extensions.first { $0["url"] as? String == Canonicals.writerRecordVersion.value?.url.absoluteString })
        return (writer, version)
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
