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


struct WorkoutRouteStudyDataTests {
    @Test
    func routeConsentControlsAdmissionAttributionAndDisclosure() async throws {
        try await Self.exerciseDisclosure(fullValidation: false)
    }

    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["TROVE_TEST_VALIDATOR_ASSETS"] != nil,
        "Requires the isolated, pinned full-validation integration setup"
    ))
    func fullyValidatedRoutePreservesItsPayloadAndIndependentGrants() async throws {
        try await Self.exerciseDisclosure(fullValidation: true)
    }
}


extension WorkoutRouteStudyDataTests {
    // Both boundaries fall inside the route. Selecting an overlap must retain the whole recording.
    private static var window: CollectionMeasurementWindow {
        .init(
            calendar: .gregorian,
            timeZone: "UTC",
            start: .absolute(.init(_type: .absolute, date: Date(timeIntervalSince1970: 1_787_005_800.25))),
            end: Date(timeIntervalSince1970: 1_787_005_800.75)
        )
    }

    private static func exerciseDisclosure(fullValidation: Bool) async throws {
        try await TestApp.withApp(token: StudyDataFixture.reader) { app, bearer in
            let fixture = try await ClinicalEventStoreTests.prepare(
                on: app, profile: CollectionObservationProfile.workout.rawValue, measurementWindow: window, routeStudies: [0]
            )
            let event = try await event(source: fixture.source, app: app, fullValidation: fullValidation)
            let receipt = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                await #expect {
                    try await store.accept(
                        event, sourceID: fixture.source.id, targets: fixture.targets(for: event), installation: fixture.installation
                    )
                } throws: { ($0 as? ServerError)?.status.code == 403 }
                try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
                return try await store.accept(
                    event, sourceID: fixture.source.id, targets: fixture.targets(for: event, studies: [0]), installation: fixture.installation
                )
            }
            try verify(try await page(fixture.studyIDs[0], token: bearer, app: app), event: event)
            #expect(try await page(fixture.studyIDs[1], token: bearer, app: app).records.isEmpty)
            try await expectAttributionDenied(event, receipt: receipt, fixture: fixture, app: app)
            try await adoptRoutes(event, receipt: receipt, fixture: fixture, app: app)
            try verify(try await page(fixture.studyIDs[1], token: bearer, app: app), event: event)
            try await ClinicalEventStoreTests.expectRows(events: 1, nodes: event.nodes.count, facts: 1, grants: 2, on: app.db)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: fixture.enrollmentIDs[0])
            }
            #expect(try await page(fixture.studyIDs[0], token: bearer, app: app).records.isEmpty)
            try verify(try await page(fixture.studyIDs[1], token: bearer, app: app), event: event)
            let sql = try #require(app.db as? any SQLDatabase)
            let stored = try #require(try await sql.raw("SELECT raw_bytes FROM clinical_events WHERE id = \(bind: receipt.eventID)").first())
            #expect(try stored.decode(column: "raw_bytes", as: Data.self) == event.rawBytes)
        }
    }

    private static func adoptRoutes(
        _ event: ValidatedExchangeEvent, receipt: ClinicalEventReceipt, fixture: ClinicalEventStoreTests.Fixture, app: Application
    ) async throws {
        _ = try await PublishedStudyFixtures.createPublishedStudy(
            on: app.db,
            studyId: fixture.studyIDs[1],
            revision: 2,
            collectionRequirements: [
                .init(
                    profile: CollectionObservationProfile.workout.rawValue,
                    sourceKind: .participantApp,
                    measurementWindow: window,
                    includeWorkoutRoutes: true
                )
            ]
        )
        // Publishing expanded scope alone grants nothing under the participant's prior acceptance.
        try await expectAttributionDenied(event, receipt: receipt, fixture: fixture, app: app)
        try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            let consent = try await ClinicalEventStoreTests.acceptConsent(enrollmentID: fixture.enrollmentIDs[1], on: app, revision: 2)
            _ = try await ClinicalAttributionStore(database: app.db).attribute(
                eventID: receipt.eventID,
                sourceID: fixture.source.id,
                commandID: UUID(),
                targets: [.init(consentID: consent.requireID(), outputFullURLs: event.outputs.map(\.fullURL))],
                installation: fixture.installation
            )
        }
    }

    private static func expectAttributionDenied(
        _ event: ValidatedExchangeEvent, receipt: ClinicalEventReceipt, fixture: ClinicalEventStoreTests.Fixture, app: Application
    ) async throws {
        try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            await #expect {
                try await ClinicalAttributionStore(database: app.db).attribute(
                    eventID: receipt.eventID,
                    sourceID: fixture.source.id,
                    commandID: UUID(),
                    targets: fixture.targets(for: event, studies: [1]),
                    installation: fixture.installation
                )
            } throws: { ($0 as? ServerError)?.status.code == 403 }
            try await ClinicalEventStoreTests.expectRows(events: 1, nodes: event.nodes.count, facts: 1, grants: 1, on: app.db)
        }
    }

    private static func event(source: SourceBinding, app: Application, fullValidation: Bool) async throws -> ValidatedExchangeEvent {
        let url = try FHIRRecordingProjectionTests.fixtureURL()
        let original = try fullValidation
            ? ImmutablePointEventFixture.bytes(source: source, fixtureURL: url)
            : LocalPointEventFixture.bytes(source: source, fixtureURL: url)
        let system = try Components.Schemas.ParticipantSource(source).nativeRecordIdentifierSystem()
        let bytes = try NativeIdentifierFixture.adding(
            [["system": system.rawValue, "value": NativeIdentifierFixture.uuid]], to: original, resourceType: "DocumentReference"
        )
        let identity = try await fullValidation ? FHIRValidationClient(application: app).validate(bytes) : "synthetic-test-only"
        return try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: identity)
    }

    private static func page(_ study: UUID, token: String?, app: Application) async throws -> Components.Schemas.StudyDataPage {
        let response = try await app.testing().sendRequest(
            .GET, "\(apiBasePath)/studies/\(study)/data?limit=1", beforeRequest: { $0.bearerAuth(token) }
        )
        try #require(response.status == .ok)
        #expect(response.headers.first(name: .cacheControl) == "no-store")
        return try response.content.decode(Components.Schemas.StudyDataPage.self)
    }

    private static func verify(_ page: Components.Schemas.StudyDataPage, event: ValidatedExchangeEvent) throws {
        let record = try #require(page.records.first)
        #expect(page.records.count == 1 && record.outputs.count == 1 && record.outputs.allSatisfy(\.isCurrent))
        let resources = try StudyDataFixture.resources(record)
        let document = try #require(resources.first { $0["resourceType"] as? String == "DocumentReference" })
        let original = try #require(JSONSerialization.jsonObject(with: event.rawBytes) as? [String: Any])
        let entries = try #require(original["entry"] as? [[String: Any]])
        let source = try #require(entries.compactMap { $0["resource"] as? [String: Any] }
            .first { $0["resourceType"] as? String == "DocumentReference" })
        for field in ["content", "identifier"] {
            let expected = try JSONSerialization.data(withJSONObject: #require(source[field]), options: [.sortedKeys])
            let actual = try JSONSerialization.data(withJSONObject: #require(document[field]), options: [.sortedKeys])
            #expect(actual == expected)
        }
        let identifiers = try #require(document["identifier"] as? [[String: Any]])
        #expect(identifiers.contains { $0["value"] as? String == NativeIdentifierFixture.uuid })
        let provenance = resources.filter { $0["resourceType"] as? String == "Provenance" }
        #expect(provenance.count == 2)
        let originalProvenance = try #require(entries.compactMap { $0["resource"] as? [String: Any] }
            .first { $0["resourceType"] as? String == "Provenance" })
        let originalEntities = try JSONSerialization.data(withJSONObject: #require(originalProvenance["entity"]), options: [.sortedKeys])
        #expect(try provenance.contains {
            guard let entities = $0["entity"] else {
                return false
            }
            return try JSONSerialization.data(withJSONObject: entities, options: [.sortedKeys]) == originalEntities
        })
        #expect(resources.contains { $0["resourceType"] as? String == "Device" })
    }
}
