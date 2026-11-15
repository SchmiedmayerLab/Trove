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


/// Composes accepted calendar history, whole-session overlap, mixed Bundle custody and study isolation.
/// Synthetic identities/validation do not establish device acquisition, offline execution or full IG conformance.
struct HistoricalMixedCollectionTests {
    @Test
    func mixedHistoricalBundleKeepsSharedHeartRateAndDistinctSleepWorkoutGrantsAfterRestart() async throws {
        try await TestApp.withApp(token: StudyDataFixture.reader) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app, consentCount: 0)
            let accepted = try await HistoricalMixedCollectionFixture.acceptPlans(fixture, app: app)
            let events = try HistoricalMixedCollectionFixture.events(source: fixture.source, lowerBounds: accepted.lowerBounds)
            let requests = zip(events, [[0, 1], [0], [1]]).map { event, studies in
                Components.Schemas.EventSubmission(eventBase64: event.rawBytes.base64EncodedString(), targets: studies.map {
                    .init(consentId: accepted.consentIDs[$0].uuidString, outputFullUrls: event.outputs.map(\.fullURL))
                })
            }
            let bundle = try ClinicalRecordBundleTests.bundle(requests, sourceID: fixture.source.id)
            let receipts = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await TestApp.clinicalService(database: app.db, validator: ClinicalEventBatchTests.validator())
                    .acceptBundle(bundle, sourceID: fixture.source.id, installation: fixture.installation)
            }
            #expect(receipts.count == 3)
            for receipt in receipts {
                guard case .EventReceipt = receipt else {
                    Issue.record("A consent-eligible historical member was rejected")
                    return
                }
            }
            try await ClinicalEventStoreTests.expectRows(
                events: 3, nodes: events.reduce(0) { $0 + $1.nodes.count }, facts: 16, grants: 17, on: app.db
            )
            try await HistoricalMixedCollectionFixture.verifyPages(fixture, events: events, app: app, token: token)
            try await HistoricalMixedCollectionFixture.verifyRestart(
                fixture, events: events, submission: (bundle, receipts), app: app, token: token
            )
        }
    }
}
