//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


enum HistoricalMixedCollectionFixture {
    struct Accepted {
        let consentIDs: [UUID]
        let lowerBounds: [Date]
    }

    static func acceptPlans(_ fixture: ClinicalEventStoreTests.Fixture, app: Application) async throws -> Accepted {
        let profiles: [[CollectionObservationProfile]] = [[.heartRate, .sleepStage], [.heartRate, .workout]]
        let history = CollectionMeasurementWindow(
            calendar: .gregorian, timeZone: "America/Los_Angeles", start: .last(.init(_type: .last, components: .init(month: 6)))
        )
        for index in 0..<2 {
            _ = try await PublishedStudyFixtures.createPublishedStudy(
                on: app.db,
                studyId: fixture.studyIDs[index],
                revision: 2,
                collectionRequirements: profiles[index].map {
                    .init(profile: $0.rawValue, sourceKind: .participantApp, measurementWindow: history, includeWorkoutRoutes: $0 == .workout)
                }
            )
        }
        return try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            var consentIDs: [UUID] = [], lowerBounds: [Date] = []
            for index in 0..<2 {
                let consent = try await ClinicalEventStoreTests.acceptConsent(enrollmentID: fixture.enrollmentIDs[index], on: app, revision: 2)
                consentIDs.append(try consent.requireID())
                let plan = try await app.grove[ConsentService.self].collectionPlan(enrollmentID: fixture.enrollmentIDs[index])
                let lower = try #require(plan.windows.first?.requirements.first?.start)
                #expect(lower < Date().addingTimeInterval(-150 * 86_400))
                lowerBounds.append(lower)
            }
            return Accepted(consentIDs: consentIDs, lowerBounds: lowerBounds)
        }
    }

    static func events(source: SourceBinding, lowerBounds: [Date]) throws -> [ValidatedExchangeEvent] {
        let heart = try shiftedEvent(
            source: source, name: "ImmutablePointEvent", sequence: 301, midpoint: #require(lowerBounds.max()).addingTimeInterval(3600)
        )
        let sleep = try shiftedEvent(source: source, name: "HealthKitSleepEvent", sequence: 302, midpoint: lowerBounds[0])
        let workout = try shiftedEvent(source: source, name: "HealthKitWorkoutEvent", sequence: 303, midpoint: lowerBounds[1])
        for (event, bound) in [(sleep, lowerBounds[0]), (workout, lowerBounds[1])] {
            #expect(event.outputs.contains { $0.effectiveAt < bound && ($0.effectiveEnd ?? $0.effectiveAt) > bound })
        }
        #expect(workout.outputs.count == 14)
        return [heart, sleep, workout]
    }

    static func verifyPages(
        _ fixture: ClinicalEventStoreTests.Fixture, events: [ValidatedExchangeEvent], app: Application, token: String?
    ) async throws {
        for (index, expected) in [[0, 1], [0, 2]].enumerated() {
            let response = try await app.testing().sendRequest(
                .GET, "\(apiBasePath)/studies/\(fixture.studyIDs[index])/data", beforeRequest: { $0.bearerAuth(token) }
            )
            try #require(response.status == .ok)
            let page = try response.content.decode(Components.Schemas.StudyDataPage.self)
            #expect(page.records.count == 2)
            let profiles = Set(page.records.flatMap(\.outputs).flatMap(\.sourceProfiles))
            #expect(Set(expected.flatMap { events[$0].outputs.map(\.profile) }).isSubset(of: profiles))
            let excluded = index == 0 ? CollectionObservationProfile.workout : .sleepStage
            #expect(!profiles.contains(excluded.rawValue))
            #expect(page.records.flatMap(\.outputs).count == (index == 0 ? 2 : 15))
            #expect(page.records.flatMap(\.outputs).allSatisfy { $0.isCurrent })
        }
    }
}


extension HistoricalMixedCollectionFixture {
    private static func shiftedEvent(source: SourceBinding, name: String, sequence: UInt64, midpoint: Date) throws -> ValidatedExchangeEvent {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
        let bytes = try LocalPointEventFixture.bytes(source: source, sequence: sequence, recordID: name, fixtureURL: url)
        var document = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var entries = try #require(document["entry"] as? [[String: Any]])
        let periods = entries.compactMap { ($0["resource"] as? [String: Any])?["effectivePeriod"] as? [String: Any] }
        let dates = try periods.flatMap { period in
            try ["start", "end"].compactMap { try (period[$0] as? String).map { try TroveDateTranscoder().decode($0) } }
        }
        let offset: TimeInterval
        if dates.isEmpty {
            offset = 0
        } else {
            let lower = try #require(dates.min()), upper = try #require(dates.max())
            offset = midpoint.timeIntervalSince(lower.addingTimeInterval(upper.timeIntervalSince(lower) / 2))
        }
        for index in entries.indices {
            var resource = try #require(entries[index]["resource"] as? [String: Any])
            if var period = resource["effectivePeriod"] as? [String: Any] {
                for key in ["start", "end"] {
                    let date = try TroveDateTranscoder().decode(#require(period[key] as? String))
                    period[key] = try TroveDateTranscoder().encode(date.addingTimeInterval(offset))
                }
                resource["effectivePeriod"] = period
            } else if resource["effectiveDateTime"] != nil {
                resource["effectiveDateTime"] = try TroveDateTranscoder().encode(midpoint)
            }
            entries[index]["resource"] = resource
        }
        document["entry"] = entries
        let record = try ExchangeRecord(validating: JSONSerialization.data(withJSONObject: document))
        return try FHIRPointProjection.project(validatedBytes: record.json, validatorIdentity: "synthetic-test-only")
    }
}


extension HistoricalMixedCollectionFixture {
    static func verifyRestart(
        _ fixture: ClinicalEventStoreTests.Fixture,
        events: [ValidatedExchangeEvent],
        submission: (bundle: Components.Schemas.RecordBundleSubmission, receipts: [Components.Schemas.EventBatchResult]),
        app: Application,
        token: String?
    ) async throws {
        try await TestDatabase.withRestartedApplication(app) { reopened in
            try await configureServices(
                for: reopened,
                storageProvider: InMemoryObjectStorageProvider(),
                validator: ClinicalEventBatchTests.validator(),
                sourceKeyring: TestApp.sourceKeyring()
            )
            _ = try await TestApp.configureTransport(for: reopened)
            try await verifyPages(fixture, events: events, app: reopened, token: token)
            let replay = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await TestApp.clinicalService(database: reopened.db, validator: ClinicalEventBatchTests.validator())
                    .acceptBundle(submission.bundle, sourceID: fixture.source.id, installation: fixture.installation)
            }
            #expect(replay == submission.receipts)
            try await ClinicalEventStoreTests.expectRows(
                events: 3, nodes: events.reduce(0) { $0 + $1.nodes.count }, facts: 16, grants: 17, on: reopened.db
            )
        }
    }
}
