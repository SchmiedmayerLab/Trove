//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SQLKit
import Testing
import TroveAPIServer
import TroveAPITypes
@testable import TroveServer
import VaporTesting


/// Grove's writer-record golden with typed source metadata, admitted for one of two consented studies and read back
/// through both study exports. The authorized study receives device unit identifiers, so its source facts are unchanged.
struct SourceFidelityExportTests {
    /// Each selected element is compared as canonical JSON with sorted keys.
    private struct Facts: Equatable {
        let metadata: [Data]
        let writerVersion: [Data]
        let identifiers: [Data]
        let sourceRevision: [Data]
    }

    private static let roleSystem = "https://grovealliance.org/fhir/mobile/CodeSystem/grove-identifier-role"
    private static let writerVersionURL = "https://grovealliance.org/fhir/mobile/StructureDefinition/grove-writer-record-version"
    private static let sourceRevisionURL = "https://grovealliance.org/fhir/healthkit/StructureDefinition/healthkit-source-revision"

    /// The decimal lexeme's trailing zero must survive custody and export byte for byte.
    private static let decimalToken = "12345.6780"

    /// The typed entries cover a free-text key, a Boolean, a decimal and a quantity whose unit differs from the measurement.
    private static var metadata: [String: Any] {
        [
            "url": FHIRHealthKitMetadataBoundary.url,
            "extension": [
                entry("com.example.note", ["valueString": "after exercise"]),
                entry("HKMetadataKeyWasUserEntered", ["valueBoolean": false]),
                entry("com.example.reading", ["valueDecimal": 12_345.678]),
                entry("com.example.ambient", [
                    "valueQuantity": ["value": 21.5, "system": "http://unitsofmeasure.org", "code": "Cel", "unit": "degC"]
                ])
            ]
        ]
    }

    @Test
    func sourceMetadataAndWriterFactsReachOnlyTheAuthorizedStudyExportUnchanged() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant"), validator: ClinicalEventBatchTests.validator()) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app, deviceUnitStudies: [0])
            let nativeSystem = try Components.Schemas.ParticipantSource(fixture.source).nativeRecordIdentifierSystem().rawValue
            let golden = try SyncIdentifierFixture.changing(SyncIdentifierFixture.bytes()) { observation in
                observation["extension"] = (observation["extension"] as? [[String: Any]] ?? []) + [Self.metadata]
            }
            let goldenURL = try Self.write(golden)
            defer { try? FileManager.default.removeItem(at: goldenURL) }
            let rekeyed = try LocalPointEventFixture.bytes(source: fixture.source, fixtureURL: goldenURL)
            // JSON serialization drops trailing zeros, so the exact lexeme is restored in the submitted text.
            let text = String(decoding: rekeyed, as: UTF8.self)
            try #require(text.components(separatedBy: "12345.678").count == 2)
            let bytes = Data(text
                .replacingOccurrences(of: SyncIdentifierFixture.nativeSystem, with: nativeSystem)
                .replacingOccurrences(of: "12345.678", with: Self.decimalToken)
                .utf8)
            let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-only")
            let admitted = try Self.facts(Self.resources(bytes))
            #expect(admitted.metadata.count == 1 && admitted.writerVersion.count == 1 && admitted.sourceRevision.count == 1)
            #expect(admitted.identifiers.count == 3, "Native UUID, readable sync identifier and writer-record identifier")
            #expect(event.syncRecordIdentifiers.count == 1 && event.nativeRecordIdentifiers.count == 1)

            try await Self.submit(bytes, event: event, fixture: fixture, app: app, token: token)
            let bearer = try await StudyRecordingFixture.readerToken()

            let authorized = try await Self.page(study: fixture.studyIDs[0], app: app, bearer: bearer)
            let record = try #require(authorized.records.first)
            #expect(authorized.records.count == 1)
            #expect(try Self.facts(StudyDataFixture.resources(record)) == admitted)
            let exported = try #require(Data(base64Encoded: record.bundleBase64))
            #expect(String(decoding: exported, as: UTF8.self).contains(Self.decimalToken))

            let unauthorized = try await Self.page(study: fixture.studyIDs[1], app: app, bearer: bearer)
            #expect(unauthorized.records.isEmpty)
            let encoded = String(decoding: try JSONEncoder().encode(unauthorized), as: UTF8.self)
            for value in [SyncIdentifierFixture.value, "after exercise", "org.example.writer", Self.decimalToken, Self.native(event)] {
                #expect(!encoded.contains(value))
            }
        }
    }
}


extension SourceFidelityExportTests {
    private static func entry(_ key: String, _ value: [String: Any]) -> [String: Any] {
        ["url": "entry", "extension": [["url": "key", "valueString": key], ["url": "value"].merging(value) { first, _ in first }]]
    }

    /// Uses the participant batch route, so submission decoding and admission run as for the app.
    private static func submit(
        _ bytes: Data, event: ValidatedExchangeEvent, fixture: ClinicalEventStoreTests.Fixture, app: Application, token: String?
    ) async throws {
        let submission = Components.Schemas.EventSubmission(
            eventBase64: bytes.base64EncodedString(),
            targets: fixture.targets(for: event, studies: [0]).map { .init(consentId: $0.consentID.uuidString, outputFullUrls: $0.outputFullURLs) }
        )
        try await app.test(.POST, "\(apiBasePath)/participant/sources/\(fixture.source.id)/events/batch", beforeRequest: {
            $0.bearerAuth(token)
            $0.sourceInstallation(fixture.installationID)
            try $0.encodeJSONBody(Components.Schemas.EventBatchSubmission(events: [submission]))
        }) { response in
            #expect(response.status == .ok)
            let results = try response.content.decode([Components.Schemas.EventBatchResult].self)
            #expect(results.count == 1 && results.first?.problemStatus == nil)
        }
        let sql = try #require(app.db as? any SQLDatabase)
        let row = try #require(try await sql.raw("SELECT raw_bytes FROM clinical_events").first())
        #expect(try row.decode(column: "raw_bytes", as: Data.self) == bytes)
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
        let provenances = resources.filter { $0["resourceType"] as? String == "Provenance" }
        let entities = provenances.flatMap { $0["entity"] as? [[String: Any]] ?? [] }
        let revisions = entities
            .flatMap { $0["extension"] as? [[String: Any]] ?? [] }
            .filter { $0["url"] as? String == sourceRevisionURL }
        return try Facts(
            metadata: canonical(extensions.filter { $0["url"] as? String == FHIRHealthKitMetadataBoundary.url }),
            writerVersion: canonical(extensions.filter { $0["url"] as? String == writerVersionURL }),
            identifiers: canonical(identifiers),
            sourceRevision: canonical(revisions)
        )
    }

    private static func canonical(_ elements: [[String: Any]]) throws -> [Data] {
        try elements.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
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
