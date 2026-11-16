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


struct WorkoutStudyDataTests {
    @Test
    func workoutDisclosurePreservesAllSegmentsThroughLateAttributionAndWithdrawal() async throws {
        try await Self.exerciseDisclosure(fullValidation: false)
    }

    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["TROVE_TEST_VALIDATOR_ASSETS"] != nil,
        "Requires the isolated, pinned full-validation integration setup"
    ))
    func fullyValidatedWorkoutReachesOnlyItsAuthorizedStudyExports() async throws {
        try await Self.exerciseDisclosure(fullValidation: true)
    }
}


extension WorkoutStudyDataTests {
    private static func exerciseDisclosure(fullValidation: Bool) async throws {
        try await TestApp.withApp(token: StudyDataFixture.reader) { app, bearer in
            let fixture = try await prepare(on: app)
            let event = try await event(source: fixture.source, app: app, fullValidation: fullValidation)
            #expect(event.outputs.count == 14)
            let receipt = try await accept(event, fixture: fixture, app: app)
            let original = try await page(fixture.studyIDs[0], token: bearer, app: app)
            try verify(original, event: event, fixture: fixture, index: 0)
            #expect(try await page(fixture.studyIDs[1], token: bearer, app: app).records.isEmpty)
            try await attribute(event, receipt: receipt, fixture: fixture, app: app)
            try verify(try await page(fixture.studyIDs[1], token: bearer, app: app), event: event, fixture: fixture, index: 1)
            try await ClinicalEventStoreTests.expectRows(events: 1, nodes: event.nodes.count, facts: 14, grants: 28, on: app.db)
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

    private static func attribute(
        _ event: ValidatedExchangeEvent, receipt: ClinicalEventReceipt, fixture: ClinicalEventStoreTests.Fixture, app: Application
    ) async throws {
        try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            let store = ClinicalAttributionStore(database: app.db)
            await #expect {
                try await store.attribute(
                    eventID: receipt.eventID,
                    sourceID: fixture.source.id,
                    commandID: UUID(),
                    targets: [.init(consentID: fixture.consentIDs[1], outputFullURLs: [event.outputs[0].fullURL])],
                    installation: fixture.installation
                )
            } throws: { ($0 as? ServerError)?.status.code == 403 }
            try await ClinicalEventStoreTests.expectRows(events: 1, nodes: event.nodes.count, facts: 14, grants: 14, on: app.db)
            _ = try await store.attribute(
                eventID: receipt.eventID,
                sourceID: fixture.source.id,
                commandID: UUID(),
                targets: fixture.targets(for: event, studies: [1]),
                installation: fixture.installation
            )
        }
    }

    private static func prepare(on app: Application) async throws -> ClinicalEventStoreTests.Fixture {
        let start = try TroveDateTranscoder().decode("2026-08-06T07:36:39Z")
        let end = try TroveDateTranscoder().decode("2026-08-06T07:36:41Z")
        return try await ClinicalEventStoreTests.prepare(
            on: app,
            profile: CollectionObservationProfile.workout.rawValue,
            measurementWindow: .init(calendar: .gregorian, timeZone: "UTC", start: .absolute(.init(_type: .absolute, date: start)), end: end)
        )
    }

    private static func accept(
        _ event: ValidatedExchangeEvent, fixture: ClinicalEventStoreTests.Fixture, app: Application
    ) async throws -> ClinicalEventReceipt {
        try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            let store = ClinicalEventStore(database: app.db)
            await #expect {
                try await store.accept(
                    event,
                    sourceID: fixture.source.id,
                    targets: [.init(consentID: fixture.consentIDs[0], outputFullURLs: [event.outputs[0].fullURL])],
                    installation: fixture.installation
                )
            } throws: { ($0 as? ServerError)?.status.code == 403 }
            try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
            return try await store.accept(
                event, sourceID: fixture.source.id, targets: fixture.targets(for: event, studies: [0]), installation: fixture.installation
            )
        }
    }

    private static func event(source: SourceBinding, app: Application, fullValidation: Bool) async throws -> ValidatedExchangeEvent {
        let url = try #require(Bundle.module.url(forResource: "HealthKitWorkoutEvent", withExtension: "json"))
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
            .GET, "\(apiBasePath)/studies/\(study)/data?limit=1", beforeRequest: { $0.bearerAuth(token) }
        )
        #expect(response.status == .ok && response.headers.first(name: .cacheControl) == "no-store")
        return try response.content.decode(Components.Schemas.StudyDataPage.self)
    }

    private static func verify(
        _ page: Components.Schemas.StudyDataPage, event: ValidatedExchangeEvent, fixture: ClinicalEventStoreTests.Fixture, index: Int
    ) throws {
        #expect(page.records.count == 1)
        let record = try #require(page.records.first)
        #expect(record.outputs.count == 14 && record.outputs.allSatisfy(\.isCurrent))
        #expect(record.outputs.filter { $0.sourceProfiles.contains(CollectionObservationProfile.workout.rawValue) }.count == 1)
        let resources = try StudyDataFixture.resources(record)
        let observations = resources.filter { $0["resourceType"] as? String == "Observation" }
        #expect(observations.count == 14)
        let sources = try sourceResources(event.rawBytes).filter { $0["resourceType"] as? String == "Observation" }
        for source in sources {
            let identifier = try canonical(source["identifier"])
            let observation = try #require(try observations.first { try canonical($0["identifier"]) == identifier })
            for field in ["effectivePeriod", "valueCodeableConcept", "code", "component"] where source[field] != nil {
                #expect(try canonical(observation[field]) == canonical(source[field]))
            }
        }
        let session = try #require(observations.first { $0["hasMember"] != nil })
        let members = try #require(session["hasMember"] as? [[String: Any]])
        #expect(members.count == 13)
        let outputAddresses = Set(record.outputs.map(\.fullUrl))
        #expect(Set(members.compactMap { $0["reference"] as? String }).isSubset(of: outputAddresses))
        let bytes = try #require(Data(base64Encoded: record.bundleBase64))
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.contains("Europe/Berlin"))
        #expect(text.contains("healthkit-workout-activity") && text.contains(NativeIdentifierFixture.uuid))
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
