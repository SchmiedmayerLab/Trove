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
@testable import TroveServer
import VaporTesting


struct SleepStudyDataTests {
    @Test
    func sleepDisclosurePreservesTheWholeRecordThroughLateAttributionAndWithdrawal() async throws {
        try await Self.exerciseDisclosure(fullValidation: false)
    }

    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["TROVE_TEST_VALIDATOR_ASSETS"] != nil,
        "Requires the isolated, pinned full-validation integration setup"
    ))
    func fullyValidatedSleepReachesOnlyItsAuthorizedStudyExports() async throws {
        try await Self.exerciseDisclosure(fullValidation: true)
    }
}


extension SleepStudyDataTests {
    private static func exerciseDisclosure(fullValidation: Bool) async throws {
        try await TestApp.withApp(token: StudyDataFixture.reader) { app, bearer in
            let fixture = try await ClinicalEventStoreTests.prepare(
                on: app,
                profile: CollectionObservationProfile.sleepStage.rawValue,
                measurementWindow: .init(calendar: .gregorian, timeZone: "UTC", start: .oldestSample(.init(_type: .oldestSample)))
            )
            let event = try await event(source: fixture.source, app: app, fullValidation: fullValidation)
            let receipt = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await ClinicalEventStore(database: app.db).accept(
                    event, sourceID: fixture.source.id, targets: fixture.targets(for: event, studies: [0]), installation: fixture.installation
                )
            }
            let original = try await page(fixture.studyIDs[0], token: bearer, app: app)
            try verify(original, event: event, fixture: fixture, index: 0)
            #expect(try await page(fixture.studyIDs[1], token: bearer, app: app).records.isEmpty)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await ClinicalAttributionStore(database: app.db).attribute(
                    eventID: receipt.eventID,
                    sourceID: fixture.source.id,
                    commandID: UUID(),
                    targets: fixture.targets(for: event, studies: [1]),
                    installation: fixture.installation
                )
            }
            try verify(try await page(fixture.studyIDs[1], token: bearer, app: app), event: event, fixture: fixture, index: 1)
            try await ClinicalEventStoreTests.expectRows(events: 1, nodes: event.nodes.count, facts: 1, grants: 2, on: app.db)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: fixture.enrollmentIDs[0])
            }
            #expect(try await page(fixture.studyIDs[0], token: bearer, app: app).records.isEmpty)
            try verify(try await page(fixture.studyIDs[1], token: bearer, app: app), event: event, fixture: fixture, index: 1)
            let sql = try #require(app.db as? any SQLDatabase)
            let stored = try #require(try await sql.raw("SELECT raw_bytes FROM clinical_events WHERE id = \(bind: receipt.eventID)").first())
            #expect(try stored.decode(column: "raw_bytes", as: Data.self) == event.rawBytes)
        }
    }

    private static func event(source: SourceBinding, app: Application, fullValidation: Bool) async throws -> ValidatedExchangeEvent {
        let url = try #require(Bundle.module.url(forResource: "HealthKitSleepEvent", withExtension: "json"))
        let original = try fullValidation
            ? ImmutablePointEventFixture.bytes(source: source, fixtureURL: url)
            : LocalPointEventFixture.bytes(source: source, fixtureURL: url)
        let system = try Components.Schemas.ParticipantSource(source).nativeRecordIdentifierSystem()
        let bytes = try NativeIdentifierFixture.adding([["system": system.rawValue, "value": NativeIdentifierFixture.uuid]], to: original)
        let identity = try await fullValidation ? FHIRValidationClient(application: app).validate(bytes) : "synthetic-test-only"
        return try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: identity)
    }

    private static func page(_ study: UUID, token: String?, app: Application) async throws -> Components.Schemas.StudyDataPage {
        let response = try await app.testing().sendRequest(
            .GET, "\(apiBasePath)/studies/\(study)/data", beforeRequest: { $0.bearerAuth(token) }
        )
        #expect(response.status == .ok && response.headers.first(name: .cacheControl) == "no-store")
        return try response.content.decode(Components.Schemas.StudyDataPage.self)
    }

    private static func verify(
        _ page: Components.Schemas.StudyDataPage, event: ValidatedExchangeEvent, fixture: ClinicalEventStoreTests.Fixture, index: Int
    ) throws {
        #expect(page.records.count == 1)
        let record = try #require(page.records.first)
        #expect(record.outputs.count == 1 && record.outputs[0].isCurrent)
        #expect(record.outputs[0].sourceProfiles.contains(CollectionObservationProfile.sleepStage.rawValue))
        let resources = try StudyDataFixture.resources(record)
        let observations = resources.filter { $0["resourceType"] as? String == "Observation" }
        #expect(observations.count == 1)
        let observation = try #require(observations.first)
        let source = try #require(try sourceResources(event.rawBytes).first { $0["resourceType"] as? String == "Observation" })
        for field in ["effectivePeriod", "valueCodeableConcept", "code"] {
            #expect(try canonical(observation[field]) == canonical(source[field]))
        }
        let bytes = try #require(Data(base64Encoded: record.bundleBase64))
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.contains("Etc/UTC"))
        #expect(text.contains("asleepDeep") && text.contains(NativeIdentifierFixture.uuid))
        #expect(text.contains(fixture.enrollmentIDs[index].uuidString.lowercased()))
        #expect(!text.contains(fixture.enrollmentIDs[1 - index].uuidString.lowercased()))
        #expect(!text.contains(fixture.source.participantIdentifierValue))
        #expect(resources.filter { $0["resourceType"] as? String == "Provenance" }.count == 2)
        #expect(resources.contains { $0["resourceType"] as? String == "Device" })
    }

    private static func sourceResources(_ bytes: Data) throws -> [[String: Any]] {
        let bundle = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        return try #require(bundle["entry"] as? [[String: Any]]).compactMap { $0["resource"] as? [String: Any] }
    }

    private static func canonical(_ value: Any?) throws -> Data {
        try JSONSerialization.data(withJSONObject: #require(value), options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
