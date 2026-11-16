// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import SQLKit
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


struct BodyWeightCollectionTests {
    @Test
    func bodyWeightRetainsExactCustodyAndOnlyAuthorizedStudyExports() async throws {
        try await Self.exercise(fullValidation: false)
    }

    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["TROVE_TEST_VALIDATOR_ASSETS"] != nil,
        "Requires the isolated, pinned full-validation integration setup"
    ))
    func groveBodyWeightPassesFullValidationAndStudyDisclosure() async throws {
        try await Self.exercise(fullValidation: true)
    }

    @Test
    func heartRateConsentCannotAdmitBodyWeight() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let event = try await BodyWeightFixture.event(source: fixture.source, app: app)
            await #expect {
                try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                    try await ClinicalEventStore(database: app.db).accept(
                        event, sourceID: fixture.source.id, targets: fixture.targets(for: event), installation: fixture.installation
                    )
                }
            } throws: { ($0 as? ServerError)?.status.code == 403 }
            try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
        }
    }
}


extension BodyWeightCollectionTests {
    private static func exercise(fullValidation: Bool) async throws {
        try await TestApp.withApp(token: StudyDataFixture.reader) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(
                on: app,
                profile: CollectionObservationProfile.bodyWeight.rawValue,
                measurementWindow: .init(calendar: .gregorian, timeZone: "UTC", start: .oldestSample(.init(_type: .oldestSample)))
            )
            let event = try await BodyWeightFixture.event(source: fixture.source, app: app, fullValidation: fullValidation)
            let receipt = try await accept(event, fixture: fixture, app: app)
            #expect(try await accept(event, fixture: fixture, app: app).eventID == receipt.eventID)
            try verify(try await page(fixture.studyIDs[0], token: token, app: app), fixture: fixture, index: 0)
            #expect(try await page(fixture.studyIDs[1], token: token, app: app).records.isEmpty)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await ClinicalAttributionStore(database: app.db).attribute(
                    eventID: receipt.eventID,
                    sourceID: fixture.source.id,
                    commandID: UUID(),
                    targets: fixture.targets(for: event, studies: [1]),
                    installation: fixture.installation
                )
            }
            try verify(try await page(fixture.studyIDs[1], token: token, app: app), fixture: fixture, index: 1)
            try await ClinicalEventStoreTests.expectRows(events: 1, nodes: event.nodes.count, facts: 1, grants: 2, on: app.db)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: fixture.enrollmentIDs[0])
            }
            #expect(try await page(fixture.studyIDs[0], token: token, app: app).records.isEmpty)
            try verify(try await page(fixture.studyIDs[1], token: token, app: app), fixture: fixture, index: 1)
            let sql = try #require(app.db as? any SQLDatabase)
            let row = try #require(try await sql.raw("SELECT raw_bytes FROM clinical_events WHERE id = \(bind: receipt.eventID)").first())
            #expect(try row.decode(column: "raw_bytes", as: Data.self) == event.rawBytes)
        }
    }

    private static func accept(
        _ event: ValidatedExchangeEvent, fixture: ClinicalEventStoreTests.Fixture, app: Application
    ) async throws -> ClinicalEventReceipt {
        try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            try await ClinicalEventStore(database: app.db).accept(
                event, sourceID: fixture.source.id, targets: fixture.targets(for: event, studies: [0]), installation: fixture.installation
            )
        }
    }

    private static func page(_ study: UUID, token: String?, app: Application) async throws -> Components.Schemas.StudyDataPage {
        let response = try await app.testing().sendRequest(
            .GET, "\(apiBasePath)/studies/\(study)/data", beforeRequest: { $0.bearerAuth(token) }
        )
        #expect(response.status == .ok && response.headers.first(name: .cacheControl) == "no-store")
        return try response.content.decode(Components.Schemas.StudyDataPage.self)
    }

    private static func verify(
        _ page: Components.Schemas.StudyDataPage, fixture: ClinicalEventStoreTests.Fixture, index: Int
    ) throws {
        #expect(page.records.count == 1)
        let record = try #require(page.records.first)
        #expect(record.outputs.count == 1 && record.outputs[0].isCurrent)
        #expect(record.outputs[0].sourceProfiles.contains(CollectionObservationProfile.bodyWeight.rawValue))
        let resources = try StudyDataFixture.resources(record)
        let observation = try #require(resources.first { $0["resourceType"] as? String == "Observation" })
        #expect(observation["effectivePeriod"] == nil && observation["effectiveDateTime"] != nil)
        let value = try #require(observation["valueQuantity"] as? [String: Any])
        #expect(value["code"] as? String == "kg")
        #expect((value["value"] as? Double) == 71.3)
        let text = String(decoding: try #require(Data(base64Encoded: record.bundleBase64)), as: UTF8.self)
        #expect(text.contains("manual-entry") && text.contains(NativeIdentifierFixture.uuid))
        #expect(text.contains(fixture.enrollmentIDs[index].uuidString.lowercased()))
        #expect(!text.contains(fixture.enrollmentIDs[1 - index].uuidString.lowercased()))
        #expect(!text.contains(fixture.source.participantIdentifierValue))
        #expect(resources.filter { $0["resourceType"] as? String == "Provenance" }.count == 2)
        #expect(resources.contains { $0["resourceType"] as? String == "Device" })
    }
}
