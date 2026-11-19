//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import GroveFHIRContract
import GroveSensorKitFHIR
import SQLKit
import Testing
import TroveAPIClient
import TroveAPIServer
import TroveAPITypes
@testable import TroveServer
import VaporTesting


/// One record granted to two studies, of which only the first publication receives device unit identifiers.
struct DeviceUnitDisclosureTests {
    private static let role = "https://grovealliance.org/fhir/mobile/CodeSystem/grove-identifier-role"
    /// Bundle identifiers HealthKit assigns to one device, for the writing source and the application Device.
    private static let writerBundle = "com.apple.health.94C8E349-0D09-4184-BF6C-AF11692FA465"
    private static let applicationBundle = "com.apple.health.0F0C8D6A-5F1B-4B8E-9A47-0C7E1D2B3A45"
    /// Facts about a kind of device or an application, which every study receives.
    private static let kindFacts = [
        "Watch7,12", "Apple Inc.", "(01)00844588003288", "org.example.writer", "\"Example Writer\"", "com.example.note", "\"Grove Test\""
    ]

    @Test
    func studyDataCarriesUnitFactsOnlyForAPublicationThatReceivesThem() async throws {
        try await TestApp.withApp(token: StudyDataFixture.reader) { app, bearer in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app, deviceUnitStudies: [0])
            let bytes = try Self.record(source: fixture.source)
            let unitFacts = try Self.unitFacts(bytes)
            #expect(unitFacts.count == 6, "Serial number, unit identity, local identifier, two names and metadata")
            let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-only")
            let targets = fixture.targets(for: event)
            let receipt = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                let receipt = try await store.accept(event, sourceID: fixture.source.id, targets: targets, installation: fixture.installation)
                #expect(try await store.accept(event, sourceID: fixture.source.id, targets: targets, installation: fixture.installation) == receipt)
                return receipt
            }
            let sql = try #require(app.db as? any SQLDatabase)
            let row = try #require(try await sql.raw("SELECT raw_bytes FROM clinical_events WHERE id = \(bind: receipt.eventID)").first())
            #expect(try row.decode(column: "raw_bytes", as: Data.self) == bytes)

            let entitled = try await Self.page(study: fixture.studyIDs[0], app: app, bearer: bearer)
            let withheld = try await Self.page(study: fixture.studyIDs[1], app: app, bearer: bearer)
            for value in unitFacts {
                #expect(entitled.text.contains(value), "\(value) reaches the study that receives unit facts")
                #expect(!withheld.text.contains(value), "\(value) is withheld from the other study")
            }
            for kind in Self.kindFacts {
                #expect(entitled.text.contains(kind) && withheld.text.contains(kind), "\(kind) describes a kind of device or writer")
            }
            #expect(entitled.policies == ["urn:trove:study-point-view-v1"])
            #expect(withheld.policies == ["urn:trove:study-point-view-v1", StudyDeviceUnitDisclosure.withheldPolicy])
            for page in [entitled, withheld] {
                let addresses = Set(page.resources.keys)
                let observation = try #require(page.resources.values.first { $0["resourceType"] as? String == "Observation" })
                let device = try #require((observation["device"] as? [String: Any])?["reference"] as? String)
                #expect(page.resources[device]?["resourceType"] as? String == "Device")
                #expect(Self.references(page.resources).isSubset(of: addresses))
            }
        }
    }

    @Test
    func deviceAssignedSourceFactsReachOnlyTheReceivingStudyUnchanged() async throws {
        try await TestApp.withApp(token: StudyDataFixture.reader) { app, bearer in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app, deviceUnitStudies: [0])
            let bytes = try Self.record(source: fixture.source, deviceAssigned: true)
            let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-only")
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await ClinicalEventStore(database: app.db).accept(
                    event, sourceID: fixture.source.id, targets: fixture.targets(for: event), installation: fixture.installation
                )
            }
            let admitted = try Self.sourceFacts(Array(Self.resources(bytes)))
            #expect(admitted.count == 4, "Application name and bundle identifier, source revision and sync identifier")
            let entitled = try await Self.page(study: fixture.studyIDs[0], app: app, bearer: bearer)
            #expect(try Self.sourceFacts(Array(entitled.resources.values)) == admitted)
            let withheld = try await Self.page(study: fixture.studyIDs[1], app: app, bearer: bearer)
            for value in [Self.writerBundle, Self.applicationBundle, "\"Example Writer\"", "\"Grove Test\""] {
                #expect(entitled.text.contains(value) && !withheld.text.contains(value), "\(value) names one device")
            }
        }
    }

    @Test
    func opaqueRecordingIsReleasedOnlyToAStudyThatReceivesUnitFacts() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant"), validator: ClinicalEventBatchTests.validator()) { app, token in
            let payload = Data("{\"device\":{\"serialNumber\":\"SERIAL-IN-PAYLOAD\"}}".utf8)
            let source = try await Self.admitNativeRecording(payload, app: app, token: token)

            let reader = try await StudyRecordingFixture.readerToken()
            var paths: [String] = []
            for study in source.studyIDs {
                paths += try await Self.recordingPaths(study: study, app: app)
            }
            try await app.test(.GET, paths[0], beforeRequest: { $0.bearerAuth(reader) }) { response in
                #expect(response.status == .ok)
                #expect(response.body.string == String(decoding: payload, as: UTF8.self))
            }
            try await app.test(.GET, paths[1], beforeRequest: { $0.bearerAuth(reader) }) { response in
                #expect(response.status == .forbidden)
                #expect(!response.body.string.contains("SERIAL-IN-PAYLOAD"))
            }
            #expect(try await StudyRecordingFixture.disclosureCount(on: app) == 1, "A refused download records no disclosure")

            for (index, study) in source.studyIDs.enumerated() {
                let page = try await Self.page(study: study, app: app, bearer: reader)
                let document = try #require(page.resources.values.first { $0["resourceType"] as? String == "DocumentReference" })
                let attachment = try #require(((document["content"] as? [[String: Any]])?.first)?["attachment"] as? [String: Any])
                #expect(attachment["url"] as? String == (index == 0 ? paths[0] : nil))
                #expect(attachment["data"] == nil && attachment["hash"] != nil && attachment["size"] != nil)
            }
        }
    }

    @Test
    func aLaterRevisionThatWithholdsAppliesToThePageAndEveryGrantsDownload() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant"), validator: ClinicalEventBatchTests.validator()) { app, token in
            let payload = Data("{\"device\":{\"serialNumber\":\"SERIAL-IN-PAYLOAD\"}}".utf8)
            let source = try await Self.admitNativeRecording(payload, app: app, token: token)
            let study = source.studyIDs[0]
            try await Self.grantUnderAWithholdingRevision(study: study, source: source, app: app)
            let reader = try await StudyRecordingFixture.readerToken()
            let paths = try await Self.recordingPaths(study: study, app: app)
            #expect(paths.count == 2, "Revision 1 receives unit facts, revision 2 withholds them")
            for path in paths {
                try await app.test(.GET, path, beforeRequest: { $0.bearerAuth(reader) }) { #expect($0.status == .forbidden) }
            }
            #expect(try await StudyRecordingFixture.disclosureCount(on: app) == 0)
            let page = try await Self.page(study: study, app: app, bearer: reader)
            #expect(page.policies.contains(StudyDeviceUnitDisclosure.withheldPolicy))
            let document = try #require(page.resources.values.first { $0["resourceType"] as? String == "DocumentReference" })
            let attachment = try #require(((document["content"] as? [[String: Any]])?.first)?["attachment"] as? [String: Any])
            #expect(attachment["url"] == nil && attachment["data"] == nil)
        }
    }
}


extension DeviceUnitDisclosureTests {
    private struct Page {
        let text: String
        let resources: [String: [String: Any]]
        let policies: [String]
    }

    /// Grove's sync identifier golden with a serial number and device metadata, rekeyed to the registered source.
    private static func record(source: SourceBinding, deviceAssigned: Bool = false) throws -> Data {
        let golden = try SyncIdentifierFixture.changing(SyncIdentifierFixture.bytes(), resourceType: "Device") { device in
            device["serialNumber"] = "SERIAL-0042"
        }
        let enriched = try SyncIdentifierFixture.changing(golden) { observation in
            let entries = [("HKDeviceSerialNumber", "SERIAL-METADATA"), ("com.example.note", "after exercise")].map { key, value in
                ["url": "entry", "extension": [["url": "key", "valueString": key], ["url": "value", "valueString": value]]]
            }
            observation["extension"] = (observation["extension"] as? [[String: Any]] ?? []) + [
                ["url": FHIRHealthKitMetadataBoundary.url, "extension": entries]
            ]
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trove-device-units-\(UUID().uuidString).json")
        var text = String(decoding: enriched, as: UTF8.self)
        if deviceAssigned {
            text = text.replacingOccurrences(of: "org.example.writer", with: writerBundle)
                .replacingOccurrences(of: "org.grovealliance.test", with: applicationBundle)
        }
        try Data(text.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let rekeyed = try LocalPointEventFixture.bytes(source: source, fixtureURL: url)
        let nativeSystem = try Components.Schemas.ParticipantSource(source).nativeRecordIdentifierSystem().rawValue
        return Data(String(decoding: rekeyed, as: UTF8.self).replacingOccurrences(of: SyncIdentifierFixture.nativeSystem, with: nativeSystem).utf8)
    }

    private static func resources(_ bytes: Data) throws -> [[String: Any]] {
        let document = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        return try #require(document["entry"] as? [[String: Any]]).compactMap { $0["resource"] as? [String: Any] }
    }

    /// The device-assigned source facts as canonical JSON: the application Device's name and bundle identifier, the
    /// source-revision extension and the readable sync identifier, in that order.
    private static func sourceFacts(_ resources: [[String: Any]]) throws -> [Data] {
        let application = resources.first { resource in
            ((resource["identifier"] as? [[String: Any]]) ?? []).contains { $0["value"] as? String == applicationBundle }
        }
        let bundle = (application?["identifier"] as? [[String: Any]])?.filter { $0["value"] as? String == applicationBundle } ?? []
        let revisions = resources.filter { $0["resourceType"] as? String == "Provenance" }
            .flatMap { $0["entity"] as? [[String: Any]] ?? [] }
            .flatMap { $0["extension"] as? [[String: Any]] ?? [] }
            .filter { $0["url"] as? String == "https://grovealliance.org/fhir/healthkit/StructureDefinition/healthkit-source-revision" }
        let sync = resources.filter { $0["resourceType"] as? String == "Observation" }
            .flatMap { $0["identifier"] as? [[String: Any]] ?? [] }
            .filter(SyncIdentifierFixture.isSyncIdentifier)
        let values: [Any] = [application?["deviceName"]].compactMap(\.self) + bundle + revisions + sync
        return try values.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
    }

    /// The exact unit fact values the admitted record states.
    private static func unitFacts(_ bytes: Data) throws -> [String] {
        let document = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let resources = try #require(document["entry"] as? [[String: Any]]).compactMap { $0["resource"] as? [String: Any] }
        var facts: [String] = []
        for device in resources where device["resourceType"] as? String == "Device" {
            let profiles = (device["meta"] as? [String: Any])?["profile"] as? [String] ?? []
            guard !profiles.contains(where: { $0.hasSuffix("application-device") }) else { continue }
            facts += (device["deviceName"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "user-friendly-name" }
                .compactMap { "\"" + ($0["name"] as? String ?? "") + "\"" }
            facts += (device["identifier"] as? [[String: Any]] ?? []).filter { identifier in
                let codes = ((identifier["type"] as? [String: Any])?["coding"] as? [[String: Any]] ?? []).compactMap { $0["code"] as? String }
                return codes.contains("recording-device") || codes.contains("device-local-identifier")
            }.compactMap { $0["value"] as? String }
            facts += [device["serialNumber"] as? String].compactMap(\.self)
        }
        // The source revision names an application (`org.example.writer`), so its name is not a unit fact.
        facts += ["SERIAL-METADATA"]
        return facts
    }

    private static func page(study: UUID, app: Application, bearer: String?) async throws -> Page {
        let response = try await app.testing().sendRequest(.GET, "\(apiBasePath)/studies/\(study)/data", beforeRequest: { $0.bearerAuth(bearer) })
        #expect(response.status == .ok)
        let page = try response.content.decode(Components.Schemas.StudyDataPage.self)
        let record = try #require(page.records.first)
        #expect(page.records.count == 1)
        let bytes = try #require(Data(base64Encoded: record.bundleBase64))
        let bundle = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let entries = try #require(bundle["entry"] as? [[String: Any]])
        let resources = try Dictionary(uniqueKeysWithValues: entries.map {
            (try #require($0["fullUrl"] as? String), try #require($0["resource"] as? [String: Any]))
        })
        let derivation = try #require(resources.values.first {
            $0["resourceType"] as? String == "Provenance" && ($0["policy"] as? [String])?.first?.hasPrefix("urn:trove:") == true
        })
        return .init(text: String(decoding: bytes, as: UTF8.self), resources: resources, policies: derivation["policy"] as? [String] ?? [])
    }

    /// Publishes revision 2 of `study`, which withholds unit facts, and grants the admitted record under it as well.
    private static func grantUnderAWithholdingRevision(
        study: UUID, source: ClinicalEventStoreTests.Fixture, app: Application
    ) async throws {
        let draft = try #require(try await Study.find(study, on: app.db))
        draft.receivesDeviceUnitIdentifiers = false
        try await draft.save(on: app.db)
        _ = try await PublishedStudyFixtures.createNextClinicalRevision(on: app.db, studyId: study)
        let sql = try #require(app.db as? any SQLDatabase)
        let event = try #require(try await sql.raw("SELECT id FROM clinical_events").first()).decode(column: "id", as: UUID.self)
        let rows = try await sql.raw("""
            SELECT DISTINCT n.full_url FROM clinical_event_nodes n JOIN study_data_grants g ON g.node_id = n.id
            WHERE g.study_id = \(bind: study)
            """)
            .all()
        let outputs = try rows.map { try $0.decode(column: "full_url", as: String.self) }
        try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            let consent = try await ClinicalEventStoreTests.acceptConsent(enrollmentID: source.enrollmentIDs[0], on: app, revision: 2)
            _ = try await ClinicalAttributionStore(database: app.db).attribute(
                eventID: event,
                sourceID: source.source.id,
                commandID: UUID(),
                targets: [.init(consentID: consent.requireID(), outputFullURLs: outputs)],
                installation: source.installation
            )
        }
    }

    /// Study recording locations for every grant of the study's recording output, ordered by revision.
    private static func recordingPaths(study: UUID, app: Application) async throws -> [String] {
        let sql = try #require(app.db as? any SQLDatabase)
        let rows = try await sql.raw("""
            SELECT g.id FROM study_data_grants g JOIN clinical_recording_attachments a ON a.node_id = g.node_id
            WHERE g.study_id = \(bind: study) ORDER BY g.revision
            """)
            .all()
        return try rows.map { StudyRecordingLocation.path(studyID: study, grantID: try $0.decode(column: "id", as: UUID.self), versions: .current) }
    }

    private static func references(_ value: Any) -> Set<String> {
        if let object = value as? [String: Any] {
            return object.reduce(into: []) { result, member in
                if member.key == "reference", let value = member.value as? String { result.insert(value) }
                result.formUnion(references(member.value))
            }
        }
        if let array = value as? [Any] {
            return array.reduce(into: []) { $0.formUnion(references($1)) }
        }
        return []
    }

    /// Grants one external native SensorKit recording to both studies; only the first publication receives unit facts.
    private static func admitNativeRecording(_ payload: Data, app: Application, token: String?) async throws -> ClinicalEventStoreTests.Fixture {
        let definition = try #require(SensorKitCatalog.current.entries.first { $0.structuredContract == .deviceUsage }?.implementedOutput)
        let window = CollectionMeasurementWindow(
            calendar: .gregorian, timeZone: "UTC", start: .absolute(.init(_type: .absolute, date: Date().addingTimeInterval(-3600)))
        )
        let summary = try #require(definition.observation?.primaryProfile)
        let requirements = [summary, SensorKitContract.recordingDocumentProfile].map { profile in
            CollectionRequirement(
                profile: profile, sourceKind: .participantApp, measurementWindow: window, sourceTypeIdentifier: definition.sourceToken
            )
        }
        let source = try await ClinicalEventStoreTests.prepare(
            on: app, requirements: [requirements, requirements], repositoryKind: .sensorKit, deviceUnitStudies: [0]
        )
        var (recording, summaryURL) = try await nativeRecording(payload, token: definition.sourceToken, source: source)
        let receipt = try await ClinicalRecordingAttachmentTests.upload(recording, source: source, on: app, token: token)
        let outputs = [recording.declaration.outputFullUrl, summaryURL]
        recording.declaration.targets = source.consentIDs.map { .init(consentId: $0.uuidString, outputFullUrls: outputs) }
        let result = try await ClinicalRecordingAttachmentTests.submit(
            recording.submission(sourceID: source.source.id, receipt: receipt), source: source, on: app, token: token
        )
        guard case .EventReceipt = try #require(result.first) else {
            throw ServerError.unexpectedError
        }
        return source
    }

    /// A device-usage summary with its external native recording: an opaque payload the disclosure rule cannot filter.
    private static func nativeRecording(
        _ bytes: Data, token: String, source: ClinicalEventStoreTests.Fixture
    ) async throws -> (recording: RecordingAttachmentFixture, summaryURL: String) {
        let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 10)
        let end = start.addingTimeInterval(5)
        let path = "recordings/native.json"
        let record = SensorKitDeviceUsageRecord(
            sourceRecordID: SensorKitSourceRecordID(UUID()),
            timestamp: start,
            durationSeconds: 5,
            totalScreenWakes: 1,
            totalUnlocks: 2,
            totalUnlockDurationSeconds: 3,
            nativeRecording: try SensorKitNativeRecording(
                title: "Synthetic native recording",
                format: .nativeRecording,
                payload: .sidecar(path: path, bytes: bytes),
                admission: .verifiedSanitizedInput
            )
        )
        let json = try await export(.deviceUsage(record), source: source.source)
        let graph = try ExchangeGraph(validating: json, kind: .active)
        let address = { (type: String) in graph.bundle.entry?.first { $0.resource?.resourceType == type }?.fullUrl?.value?.url.absoluteString }
        let output = try #require(address("DocumentReference")), summary = try #require(address("Observation"))
        let declaration = try Components.Schemas.RecordingTransferDeclaration(
            attachmentPath: path,
            outputFullUrl: output,
            profile: SensorKitContract.recordingDocumentProfile,
            sourceTypeIdentifier: token,
            format: RegisteredRecordingFormat.nativeRecording.rawValue,
            effectiveAt: start,
            effectiveEnd: end,
            content: .init(
                encoding: .identity,
                storedByteCount: Int64(bytes.count),
                storedSHA256: ArtifactStore.digest(bytes),
                sourceByteCount: Int64(bytes.count),
                sourceSHA256: ArtifactStore.digest(bytes)
            ),
            targets: source.consentIDs.map { .init(consentId: $0.uuidString, outputFullUrls: [output]) }
        )
        return (.init(record: json, stored: bytes, declaration: declaration), summary)
    }

    private static func export(_ record: SensorKitRecord, source binding: SourceBinding) async throws -> Data {
        let producer = try ExchangeProducer(
            identityScope: .init(
                root: IdentifierSystem(binding.identifierRoot),
                keyID: binding.keyID.uuidString.lowercased(),
                epoch: KeyEpoch(1),
                key: SymmetricKey(data: Data(repeating: 0x35, count: 32))
            ),
            subject: .logical(.init(system: IdentifierSystem(binding.participantIdentifierSystem), value: binding.participantIdentifierValue)),
            application: .init(name: "Trove", bundleIdentifier: "org.example.Trove", version: "1"),
            host: .init(operatingSystemName: "Linux", operatingSystemVersion: "6")
        )
        let exporter = try SensorKitFHIRExporter(
            producer: producer,
            repositoryScope: .init(system: IdentifierSystem("https://example.test/sensor-repository"), value: "primary"),
            visitLocationIdentifierSystem: IdentifierSystem("https://example.test/sensor-location")
        )
        var records: [Data] = []
        try await exporter.export([record], sourceTimeZone: #require(TimeZone(secondsFromGMT: 0)), recordingDevice: nil, at: Date()) {
            switch $0.outcome {
            case .record(let record): records.append(record.json)
            case .refused(let failure): throw failure
            }
        }
        return try #require(records.first)
    }
}
