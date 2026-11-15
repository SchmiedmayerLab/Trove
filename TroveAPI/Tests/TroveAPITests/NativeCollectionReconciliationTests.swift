//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveHealthKit
import Testing
@testable import TroveAPIClient


struct NativeCollectionReconciliationTests {
    private typealias Fixture = HeartRatePlannerFixture

    private static func plan() -> Components.Schemas.ParticipantCollectionPlan {
        var plan = Fixture.plan(start: 100, end: 150)
        plan.endsAt = Fixture.date(150)
        plan.windows[0].end = plan.endsAt
        plan.windows[0].requirements[0].profile = CollectionObservationProfile.sleepStage.rawValue
        plan.windows[0].requirements[0].sourceTypeIdentifier = HealthKitQueryDefinition.Stream.sleepStage.sourceTypeIdentifier
        return plan
    }

    private static func instruction(
        _ plan: Components.Schemas.ParticipantCollectionPlan
    ) throws -> Components.Schemas.NativeCollectionReconciliationInstruction {
        let window = try #require(plan.windows.first)
        return .init(
            id: UUID().uuidString,
            sourceId: DeliveryFixture.sourceID.uuidString,
            enrollmentId: plan.enrollmentId,
            studyId: plan.studyId,
            stateVersion: plan.stateVersion,
            issuedAt: Fixture.date(200),
            expiresAt: Fixture.date(250),
            consentId: window.consentId,
            publicationId: window.publicationId,
            revision: window.revision,
            profile: CollectionObservationProfile.sleepStage.rawValue,
            sourceTypeIdentifier: try #require(HealthKitQueryDefinition.Stream.sleepStage.sourceTypeIdentifier),
            start: Fixture.date(100),
            end: Fixture.date(150),
            includeWorkoutRoutes: false
        )
    }

    @Test
    func explicitInstructionPreservesTheEndedPlanAndSelectsWholeOverlappingSleepOnly() throws {
        let plan = Self.plan()
        let id = try #require(UUID(uuidString: plan.enrollmentId))
        let cached = try ParticipantCollectionSnapshot(plans: [plan], enrollmentIDs: [id])
        #expect(try cached.active(at: Fixture.date(200)).acquisitionStreams.isEmpty)
        let value = try Self.instruction(plan)
        let authority = try NativeCollectionReconciliation(value, plan: plan, sourceID: DeliveryFixture.sourceID, at: Fixture.date(200))
        let selected = try cached.reconciling(authority).active(at: Fixture.date(200))
        #expect(selected.plans.first?.endsAt == plan.endsAt)
        #expect(selected.acquisitionStreams == [.sleepStage])
        #expect(authority.contains(sampleStart: Fixture.date(90), sampleEnd: Fixture.date(160)))
        #expect(!authority.contains(sampleStart: Fixture.date(150), sampleEnd: Fixture.date(160)))
        #expect(try selected.consentIDs(
            profile: .sleepStage,
            start: Fixture.date(90),
            end: Fixture.date(160),
            sourceTypeIdentifier: HealthKitQueryDefinition.Stream.sleepStage.sourceTypeIdentifier
        ) == [authority.consentID])
        #expect(throws: ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized) {
            try selected.active(at: Fixture.date(250))
        }
        #expect(try cached.active(at: Fixture.date(200)).acquisitionStreams.isEmpty)
    }

    @Test(arguments: ["source", "state", "window", "expiry", "consent"])
    func changedOrStaleInstructionNeverAcquires(mode: String) throws {
        let plan = Self.plan()
        var value = try Self.instruction(plan)
        switch mode {
        case "source": value.sourceId = UUID().uuidString
        case "state": value.stateVersion += 1
        case "window": value.start = Fixture.date(99)
        case "expiry": value.expiresAt = Fixture.date(200)
        default: value.consentId = UUID().uuidString
        }
        #expect(throws: (any Error).self) {
            try NativeCollectionReconciliation(value, plan: plan, sourceID: DeliveryFixture.sourceID, at: Fixture.date(200))
        }
    }

    @Test
    func renewalKeepsTheOriginalPredicateAndCannotBecomeAnOrdinaryOfflinePlan() async throws {
        let plan = Self.plan()
        var value = try Self.instruction(plan)
        let first = try NativeCollectionReconciliation(value, plan: plan, sourceID: DeliveryFixture.sourceID, at: Fixture.date(200))
        value.issuedAt = Fixture.date(240)
        value.expiresAt = Fixture.date(290)
        let renewed = try NativeCollectionReconciliation(value, plan: plan, sourceID: DeliveryFixture.sourceID, at: Fixture.date(240))
        #expect(renewed.renews(first) && renewed.definition == first.definition)
        try await DeliveryFixture.withJournal { journal, _ in
            let state = try await Fixture.retain([plan], in: journal)
            let original = try #require(state.snapshot)
            let temporary = try original.reconciling(renewed)
            await #expect(throws: EventDeliveryJournal.JournalError.invalidConfiguration) {
                try await journal.retainCollectionSnapshot(temporary, replacing: state)
            }
            #expect(try await journal.collectionState().collections.first?.plan.endsAt == plan.endsAt)
        }
    }

    @Test(arguments: [false, true])
    func routeSweepRequiresTheAcceptedRouteOption(accepted: Bool) throws {
        var plan = Self.plan()
        plan.windows[0].requirements[0].profile = CollectionObservationProfile.workout.rawValue
        plan.windows[0].requirements[0].sourceTypeIdentifier = HealthKitQueryDefinition.Stream.workout.sourceTypeIdentifier
        plan.windows[0].requirements[0].includeWorkoutRoutes = accepted
        var value = try Self.instruction(plan)
        value.profile = CollectionObservationProfile.healthKitRecording.rawValue
        value.sourceTypeIdentifier = SampleType.workoutRoute.hkSampleType.identifier
        value.includeWorkoutRoutes = true
        let authority = try? NativeCollectionReconciliation(value, plan: plan, sourceID: DeliveryFixture.sourceID, at: Fixture.date(200))
        #expect((authority?.definition.stream == .workoutRoute) == accepted)
        #expect((authority != nil) == accepted)
    }
}
