//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

#if canImport(HealthKit)

import Foundation
import GroveFHIRContract
import GroveHealthKit
import HealthKit
import Testing
@testable import TroveAPIClient
@testable import TroveHealthKit


struct NativeReconciliationAcquisitionTests {
    private typealias Fixture = HeartRatePlannerFixture

    private struct Setup {
        let state: ParticipantCollectionState
        let instruction: Components.Schemas.NativeCollectionReconciliationInstruction
        let id: UUID
        let consentID: UUID
        let now: Date
    }

    private static var application: ApplicationDevice {
        get throws { try .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1") }
    }

    private static var host: HostDevice {
        get throws { try .init(operatingSystemVersion: "27.2") }
    }

    /// An enrollment that ended 100 seconds ago with one sleep window over the 400 seconds before its end.
    private static func setup(_ journal: EventDeliveryJournal) async throws -> Setup {
        let now = Date()
        var plan = Fixture.plan()
        plan.asOf = now
        plan.endsAt = now.addingTimeInterval(-100)
        plan.windows[0].start = now.addingTimeInterval(-1_000)
        plan.windows[0].end = plan.endsAt
        plan.windows[0].requirements[0].profile = CollectionObservationProfile.sleepStage.rawValue
        plan.windows[0].requirements[0].sourceTypeIdentifier = HealthKitQueryDefinition.Stream.sleepStage.sourceTypeIdentifier
        plan.windows[0].requirements[0].start = now.addingTimeInterval(-500)
        plan.windows[0].requirements[0].end = plan.endsAt
        let state = try await Fixture.retain([plan], in: journal)
        let window = plan.windows[0], requirement = window.requirements[0]
        let instruction = Components.Schemas.NativeCollectionReconciliationInstruction(
            id: UUID().uuidString,
            sourceId: DeliveryFixture.sourceID.uuidString,
            enrollmentId: plan.enrollmentId,
            studyId: plan.studyId,
            stateVersion: plan.stateVersion,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(900),
            consentId: window.consentId,
            publicationId: window.publicationId,
            revision: window.revision,
            profile: requirement.profile,
            sourceTypeIdentifier: try #require(requirement.sourceTypeIdentifier),
            start: requirement.start,
            end: try #require(requirement.end),
            includeWorkoutRoutes: false
        )
        return Setup(
            state: state,
            instruction: instruction,
            id: try #require(UUID(uuidString: instruction.id)),
            consentID: try #require(UUID(uuidString: window.consentId)),
            now: now
        )
    }

    private static func sleep(from start: Date, to end: Date) -> HKCategorySample {
        HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: HKCategoryValueSleepAnalysis.asleepCore.rawValue, start: start, end: end)
    }

    private static func anchor(_ value: Int) -> QueryAnchor { QueryAnchor(HKQueryAnchor(fromValue: value)) }

    private static func expectFiniteCompletion(
        _ acquisition: HealthKitAcquisition, selection: HealthKitAcquisition.Selection, journal: EventDeliveryJournal
    ) async throws {
        let last = try await acquisition.collect(
            localID: DeliveryFixture.epoch, application: try Self.application, host: try Self.host, selection: selection
        ) { _, _ in .init(added: [], deletedIDs: [], nextAnchor: Self.anchor(2)) }
        #expect(last.isCaughtUp)
        #expect(try await journal.completedNativeReconciliations(for: DeliveryFixture.sourceID).map(\.id) == [selection.queryID])
        await #expect(throws: EventDeliveryJournal.JournalError.staleCheckpoint) {
            try await acquisition.collect(
                localID: DeliveryFixture.epoch, application: try Self.application, host: try Self.host, selection: selection
            ) { _, _ in
                Issue.record("A completed sweep must not query HealthKit again")
                return .init(added: [], deletedIDs: [], nextAnchor: Self.anchor(3))
            }
        }
    }

    @Test
    func endedPlanAloneNeverReachesHealthKit() async throws {
        let definition = try HealthKitQueryDefinition(profile: .sleepStage, kind: .live, start: Date().addingTimeInterval(-2_000))
        try await DeliveryFixture.withJournal(query: definition.encoded()) { journal, _ in
            _ = try await Self.setup(journal)
            let acquisition = try HealthKitAcquisition(journal: journal, scope: DeliveryFixture.scope) {}
            await #expect(throws: ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized) {
                try await acquisition.collect(localID: DeliveryFixture.epoch, application: try Self.application, host: try Self.host) { _, _ in
                    Issue.record("An ended enrollment plan must not query HealthKit")
                    return .init(added: [], deletedIDs: [], nextAnchor: Self.anchor(1))
                }
            }
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
        }
    }

    @Test
    func lateFinalizedOverlappingSleepIsStagedOnceAndTheSweepIsFinite() async throws {
        let definition = try HealthKitQueryDefinition(profile: .sleepStage, kind: .live, start: Date().addingTimeInterval(-2_000))
        try await DeliveryFixture.withJournal(query: definition.encoded()) { journal, _ in
            let setup = try await Self.setup(journal)
            let ordinary = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            try await journal.retainNativeReconciliations([setup.instruction], for: DeliveryFixture.sourceID, replacing: setup.state)
            let acquisition = try HealthKitAcquisition(journal: journal, scope: DeliveryFixture.scope) {}
            // Starts before the window and ends inside it; the second session lies wholly after the window.
            let spanning = Self.sleep(from: setup.now.addingTimeInterval(-600), to: setup.now.addingTimeInterval(-450))
            let outside = Self.sleep(from: setup.now.addingTimeInterval(-90), to: setup.now.addingTimeInterval(-50))
            let selection = HealthKitAcquisition.Selection(queryID: setup.id, state: setup.state, kind: .reconciliation)
            let page = try await acquisition.collect(
                localID: DeliveryFixture.epoch, application: try Self.application, host: try Self.host, selection: selection
            ) { query, _ in
                #expect(query.kind == .historical && query.usesOverlapPredicate && query.stream == .sleepStage)
                #expect(query.start == setup.instruction.start && query.end == setup.instruction.end)
                return try HealthKitAcquisition.partition(
                    .init(added: [spanning, outside], deletedIDs: [], nextAnchor: Self.anchor(1)), definition: query
                )
            }
            let eventID = try #require(page.eventIDs.first)
            #expect(page.eventIDs.count == 1)
            #expect(try await journal.pendingDeliveryIDs() == [eventID])
            let attempt = try #require(try await journal.prepareAttempt(eventID))
            #expect(attempt.commitment.targetIntent.targets.map(\.consentID) == [setup.consentID])
            let text = String(decoding: attempt.bytes, as: UTF8.self)
            #expect(text.contains(spanning.uuid.uuidString.lowercased()) && !text.contains(outside.uuid.uuidString.lowercased()))
            #expect(try await journal.completedNativeReconciliations(for: DeliveryFixture.sourceID).isEmpty)

            try await Self.expectFiniteCompletion(acquisition, selection: selection, journal: journal)
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID) == ordinary)
            #expect(try await journal.pendingDeliveryIDs() == [eventID])
        }
    }

    @Test
    func localWithdrawalStopsARetainedInstructionBeforeItsQuery() async throws {
        let definition = try HealthKitQueryDefinition(profile: .sleepStage, kind: .live, start: Date().addingTimeInterval(-2_000))
        try await DeliveryFixture.withJournal(query: definition.encoded()) { journal, _ in
            let setup = try await Self.setup(journal)
            try await journal.retainNativeReconciliations([setup.instruction], for: DeliveryFixture.sourceID, replacing: setup.state)
            let enrollmentID = try #require(UUID(uuidString: setup.instruction.enrollmentId))
            let stopped = try await journal.stopCollection(for: enrollmentID)
            let acquisition = try HealthKitAcquisition(journal: journal, scope: DeliveryFixture.scope) {}
            for state in [setup.state, stopped] {
                await #expect(throws: (any Error).self) {
                    try await acquisition.collect(
                        localID: DeliveryFixture.epoch,
                        application: try Self.application,
                        host: try Self.host,
                        selection: .init(queryID: setup.id, state: state, kind: .reconciliation)
                    ) { _, _ in
                        Issue.record("A withdrawn enrollment must not query HealthKit")
                        return .init(added: [], deletedIDs: [], nextAnchor: Self.anchor(1))
                    }
                }
            }
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID, queryID: setup.id).cursor == nil)
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
        }
    }
}

#endif
