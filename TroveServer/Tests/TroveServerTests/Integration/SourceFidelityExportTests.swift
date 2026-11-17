//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPIServer
import TroveAPITypes
@testable import TroveServer
import VaporTesting


/// Grove's writer-record golden with typed source metadata, admitted for one of two consented studies and read back
/// through both study exports.
struct SourceFidelityExportTests {
    private struct Facts: Equatable {
        let metadata: NSArray
        let writerVersion: NSArray
        let identifiers: NSArray
        let sourceRevision: NSArray
    }

    private static let roleSystem = "https://grovealliance.org/fhir/mobile/CodeSystem/grove-identifier-role"
    private static let writerVersionURL = "https://grovealliance.org/fhir/mobile/StructureDefinition/grove-writer-record-version"
    private static let sourceRevisionURL = "https://grovealliance.org/fhir/healthkit/StructureDefinition/healthkit-source-revision"

    /// The typed entries cover a free-text key, a Boolean and a quantity whose unit differs from the measurement.
    private static var metadata: [String: Any] {
        [
            "url": FHIRHealthKitMetadataBoundary.url,
            "extension": [
                entry("com.example.note", ["valueString": "after exercise"]),
                entry("HKMetadataKeyWasUserEntered", ["valueBoolean": false]),
                entry("com.example.ambient", [
                    "valueQuantity": ["value": 21.5, "system": "http://unitsofmeasure.org", "code": "Cel", "unit": "degC"]
                ])
            ]
        ]
    }

    @Test
    func sourceMetadataAndWriterFactsReachOnlyTheAuthorizedStudyExportUnchanged() async throws {
        try await TestApp.withApp(token: StudyDataFixture.reader) { app, bearer in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let nativeSystem = try Components.Schemas.ParticipantSource(fixture.source).nativeRecordIdentifierSystem().rawValue
            let golden = try SyncIdentifierFixture.changing(SyncIdentifierFixture.bytes()) { observation in
                observation["extension"] = (observation["extension"] as? [[String: Any]] ?? []) + [Self.metadata]
            }
            let goldenURL = try Self.write(golden)
            defer { try? FileManager.default.removeItem(at: goldenURL) }
            let rekeyed = try LocalPointEventFixture.bytes(source: fixture.source, fixtureURL: goldenURL)
            let bytes = Data(String(decoding: rekeyed, as: UTF8.self).replacingOccurrences(
                of: SyncIdentifierFixture.nativeSystem, with: nativeSystem
            ).utf8)
            let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-only")
            let admitted = try Self.facts(Self.resources(bytes))
            #expect(admitted.metadata.count == 1 && admitted.writerVersion.count == 1 && admitted.sourceRevision.count == 1)
            #expect(admitted.identifiers.count == 3, "Native UUID, readable sync identifier and writer-record identifier")
            #expect(event.syncRecordIdentifiers.count == 1 && event.nativeRecordIdentifiers.count == 1)

            _ = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await ClinicalEventStore(database: app.db).accept(
                    event, sourceID: fixture.source.id, targets: fixture.targets(for: event, studies: [0]), installation: fixture.installation
                )
            }

            let authorized = try await Self.page(study: fixture.studyIDs[0], app: app, bearer: bearer)
            let record = try #require(authorized.records.first)
            #expect(authorized.records.count == 1)
            #expect(try Self.facts(StudyDataFixture.resources(record)) == admitted)

            let unauthorized = try await Self.page(study: fixture.studyIDs[1], app: app, bearer: bearer)
            #expect(unauthorized.records.isEmpty)
            let encoded = String(decoding: try JSONEncoder().encode(unauthorized), as: UTF8.self)
            for value in [SyncIdentifierFixture.value, "after exercise", "org.example.writer", Self.native(event)] {
                #expect(!encoded.contains(value))
            }
        }
    }
}


extension SourceFidelityExportTests {
    private static func entry(_ key: String, _ value: [String: Any]) -> [String: Any] {
        ["url": "entry", "extension": [["url": "key", "valueString": key], ["url": "value"].merging(value) { first, _ in first }]]
    }

    private static func write(_ bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trove-source-fidelity-\(UUID().uuidString).json")
        try bytes.write(to: url)
        return url
    }

    private static func resources(_ bytes: Data) throws -> [[String: Any]] {
        let bundle = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        return try #require(bundle["entry"] as? [[String: Any]]).compactMap { $0["resource"] as? [String: Any] }
    }

    /// Selects the source metadata, writer facts, readable sync identifier and native UUID exactly as encoded.
    private static func facts(_ resources: [[String: Any]]) throws -> Facts {
        let observation = try #require(resources.first { $0["resourceType"] as? String == "Observation" })
        let extensions = observation["extension"] as? [[String: Any]] ?? []
        let identifiers = (observation["identifier"] as? [[String: Any]] ?? []).filter { identifier in
            let roles = ((identifier["type"] as? [String: Any])?["coding"] as? [[String: Any]] ?? []).filter {
                $0["system"] as? String == roleSystem
            }
            // Native and sync identifiers carry no Grove role; writer records carry the writer-record role.
            return roles.isEmpty || roles.contains { $0["code"] as? String == "writer-record" }
        }
        let revisions = resources.filter { $0["resourceType"] as? String == "Provenance" }.flatMap { provenance in
            (provenance["entity"] as? [[String: Any]] ?? []).flatMap { $0["extension"] as? [[String: Any]] ?? [] }
        }.filter { $0["url"] as? String == sourceRevisionURL }
        return Facts(
            metadata: extensions.filter { $0["url"] as? String == FHIRHealthKitMetadataBoundary.url } as NSArray,
            writerVersion: extensions.filter { $0["url"] as? String == writerVersionURL } as NSArray,
            identifiers: identifiers as NSArray,
            sourceRevision: revisions as NSArray
        )
    }

    private static func page(study: UUID, app: Application, bearer: String?) async throws -> Components.Schemas.StudyDataPage {
        let response = try await app.testing().sendRequest(.GET, "\(apiBasePath)/studies/\(study)/data", beforeRequest: { $0.bearerAuth(bearer) })
        #expect(response.status == .ok)
        return try response.content.decode(Components.Schemas.StudyDataPage.self)
    }

    private static func native(_ event: ValidatedExchangeEvent) -> String {
        event.nativeRecordIdentifiers.first?.value ?? "missing-native-identifier"
    }
}
