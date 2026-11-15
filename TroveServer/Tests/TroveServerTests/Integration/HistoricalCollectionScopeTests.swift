//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import Testing
import TroveAPIClient
import TroveAPIServer
@testable import TroveServer
import VaporTesting


struct HistoricalCollectionScopeTests {
    @Test
    func historicalPublicationConsentPlanAndAdmissionUseTheSameRetainedBounds() async throws {
        try await PublicationWorkflowFixtures.withApp { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app, consentCount: 0)
            try await Self.publishHistory(studyID: fixture.studyIDs[0], app: app, token: token)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let service = app.grove[ConsentService.self]
                let (presentation, _) = try await service.getPresentation(enrollmentId: fixture.enrollmentIDs[0], locale: "en-US", revision: 2)
                #expect(presentation.markdown.contains("6 months"))
                #expect(presentation.markdown.contains("America/Los_Angeles"))
                #expect(presentation.markdown.contains("Duration from enrollment: 6 months"))
                let consent = try await ClinicalEventStoreTests.acceptConsent(enrollmentID: fixture.enrollmentIDs[0], on: app, revision: 2)
                let stored = try #require(try await EnrollmentConsent.find(consent.requireID(), on: app.db))
                let retained = try #require(stored.collectionScope?.requirements.first?.window.start)
                let plan = try await service.collectionPlan(enrollmentID: fixture.enrollmentIDs[0])
                #expect(plan.endsAt == nil, "Publishing and adopting a new period cannot change an existing enrollment end.")
                let scope = try #require(plan.windows.first?.requirements.first)
                #expect(scope.start == retained)
                #expect(scope.start < (try #require(stored.createdAt)))
                let client = try ParticipantCollectionSnapshot(plans: [plan], enrollmentIDs: [fixture.enrollmentIDs[0]])
                #expect(client.heartRateQueryStart == retained)
                #expect(try client.consentIDs(forHeartRateAt: retained) == [consent.requireID()])
                try await Self.verifyAdmission(fixture: fixture, consent: consent, lower: retained, app: app)
                let draft = try #require(try await Study.find(fixture.studyIDs[0], on: app.db))
                draft.collectionRequirements = []
                try await draft.save(on: app.db)
                let later = try await service.collectionPlan(enrollmentID: fixture.enrollmentIDs[0])
                #expect(later.windows == plan.windows)
                #expect(try await EnrollmentConsent.find(consent.requireID(), on: app.db)?.collectionScope == stored.collectionScope)
            }
        }
    }

    @Test
    func newlyAcceptedHistoryGrantsExistingDataWithoutAnotherUpload() async throws {
        try await PublicationWorkflowFixtures.withApp { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app, consentCount: 1)
            let event = ClinicalEventStoreTests.event(source: fixture.source)
            let receipt = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await ClinicalEventStore(database: app.db).accept(
                    event, sourceID: fixture.source.id, targets: [fixture.targets[0]], installation: fixture.installation
                )
            }
            try await Self.publishHistory(studyID: fixture.studyIDs[1], app: app, token: token)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let later = try await ClinicalEventStoreTests.acceptConsent(enrollmentID: fixture.enrollmentIDs[1], on: app, revision: 2)
                #expect(try #require(later.createdAt) > event.outputs[0].effectiveAt)
                let target = ClinicalEventTarget(consentID: try later.requireID(), outputFullURLs: ["urn:uuid:point"])
                _ = try await ClinicalAttributionStore(database: app.db).attribute(
                    eventID: receipt.eventID,
                    sourceID: fixture.source.id,
                    commandID: UUID(),
                    targets: [target],
                    installation: fixture.installation
                )
            }
            try await ClinicalEventStoreTests.expectRows(events: 1, nodes: 2, facts: 1, grants: 2, on: app.db)
        }
    }
}


extension HistoricalCollectionScopeTests {
    private static func publishHistory(studyID: UUID, app: Application, token: String?) async throws {
        let study = try #require(try await Study.find(studyID, on: app.db))
        let window = CollectionMeasurementWindow(
            calendar: .gregorian,
            timeZone: "America/Los_Angeles",
            start: .last(.init(_type: .last, components: .init(month: 6)))
        )
        let period = EnrollmentPeriod(calendar: .gregorian, timeZone: "America/Los_Angeles", duration: .init(month: 6))
        let patch = Components.Schemas.StudyPatchInput(enrollmentPeriod: period, collectionRequirements: [
            .init(measurementWindow: window, profile: CollectionRequirement.supportedProfile, sourceKind: .participantApp)
        ])
        try await app.test(.PATCH, "\(apiBasePath)/studies/\(studyID)", beforeRequest: { request in
            request.bearerAuth(token)
            request.headers.replaceOrAdd(name: "If-Match", value: "\"\(study.draftRevision)\"")
            try request.encodeJSONBody(patch)
        }) { response in
            try #require(response.status == .ok)
            let returned = try response.content.decode(Components.Schemas.StudyResponse.self)
            #expect(returned.collectionRequirements[0].measurementWindow == window)
            #expect(returned.enrollmentPeriod == period)
        }
        let published = try await PublicationWorkflowFixtures.publish(studyID, app: app, token: token)
        try #require(published.status == .created)
    }

    private static func verifyAdmission(
        fixture: ClinicalEventStoreTests.Fixture, consent: EnrollmentConsent, lower: Date, app: Application
    ) async throws {
        let targets = [ClinicalEventTarget(consentID: try consent.requireID(), outputFullURLs: ["urn:uuid:point"])]
        let store = ClinicalEventStore(database: app.db)
        let outside = ClinicalEventStoreTests.event(source: fixture.source, sequence: 1, effectiveAt: lower.addingTimeInterval(-0.001))
        await #expect {
            try await store.accept(outside, sourceID: fixture.source.id, targets: targets, installation: fixture.installation)
        } throws: { ($0 as? ServerError)?.status.code == 403 }
        try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
        let inside = ClinicalEventStoreTests.event(source: fixture.source, sequence: 2, effectiveAt: lower)
        _ = try await store.accept(inside, sourceID: fixture.source.id, targets: targets, installation: fixture.installation)
        try await ClinicalEventStoreTests.expectRows(events: 1, nodes: 2, facts: 1, grants: 1, on: app.db)
    }
}
