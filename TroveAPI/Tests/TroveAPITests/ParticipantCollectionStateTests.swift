//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import TroveAPIClient


struct ParticipantCollectionStateTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 100.123456)

    @Test
    func oldAcceptedPlansSurviveReopenWithoutExpiringOrMovingHistoricalBounds() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let initial = try await journal.collectionState()
            #expect(initial.snapshot == nil)
            let plan = Self.plan()
            let retained = try await journal.retainCollectionSnapshot(Self.snapshot([plan]), replacing: initial)
            let snapshot = try #require(retained.snapshot)
            #expect(snapshot.heartRateQueryStart == Self.start.addingTimeInterval(-15_552_000))
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let restored = try await reopened.collectionState()
            #expect(restored.revision == retained.revision)
            #expect(try #require(restored.snapshot).hasSameAuthority(as: snapshot))
            // The synthetic acceptance is decades old. There is no wall-clock TTL or renewed relative window.
            #expect(restored.snapshot?.permitsHeartRateAcquisition == true)
            #expect(restored.snapshot?.heartRateQueryStart == snapshot.heartRateQueryStart)
            let checkpoint = try await reopened.collectionCheckpoint(for: DeliveryFixture.sourceID, state: restored)
            _ = try await reopened.stage(from: checkpoint, nextCursor: Data([1]), payloads: [])
            await reopened.close()
        }
    }

    @Test
    func withdrawalInvalidatesInflightStagingAcrossConnectionsAndPreservesQueuedConsent() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            var plans = [Self.plan(), Self.plan()]
            plans[0].windows[0].consentId = DeliveryFixture.consentID.uuidString.lowercased()
            let state = try await journal.retainCollectionSnapshot(Self.snapshot(plans), replacing: journal.collectionState())
            let first = try await journal.collectionCheckpoint(for: DeliveryFixture.sourceID, state: state)
            let payload = try DeliveryFixture.payload(sequence: 1, changes: ["retained-original-consent"])
            let ids = try await journal.stage(from: first, nextCursor: Data([1]), payloads: [payload])
            let inflight = try await journal.collectionCheckpoint(for: DeliveryFixture.sourceID, state: state)
            let other = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let stopped = try await other.stopCollection(for: #require(UUID(uuidString: plans[0].enrollmentId)))
            await other.close()
            await #expect(throws: DeliveryJournalError.staleCheckpoint) {
                try await journal.stage(from: inflight, nextCursor: Data([2]), payloads: [])
            }
            await #expect(throws: DeliveryJournalError.staleCollectionState) {
                try await journal.collectionCheckpoint(for: DeliveryFixture.sourceID, state: state)
            }
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID).cursor == Data([1]))
            #expect(try await journal.pendingDeliveryIDs() == ids)
            let deliveryID = try #require(ids.first)
            let queued = try #require(try await journal.prepareAttempt(deliveryID))
            #expect(queued.bytes == payload.bytes)
            #expect(try TroveDeliveryContract.serializedTargets(for: queued.commitment)
                == TroveDeliveryContract.serializedTargets(for: payloadCommitment(payload)))
            let selected = try #require(stopped.snapshot).consentIDs(forHeartRateAt: Self.start)
            #expect(selected == [try #require(UUID(uuidString: plans[1].windows[0].consentId))])
        }
    }

    @Test
    func lateRefreshCannotUndoLocalWithdrawalIncludingAfterRestart() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let plan = Self.plan()
            let initial = try await journal.collectionState()
            let state = try await journal.retainCollectionSnapshot(Self.snapshot([plan]), replacing: initial)
            let id = try #require(UUID(uuidString: plan.enrollmentId))
            _ = try await journal.stopCollection(for: id)
            await #expect(throws: DeliveryJournalError.staleCollectionState) {
                try await journal.retainCollectionSnapshot(Self.snapshot([plan]), replacing: state)
            }
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let stopped = try await reopened.collectionState()
            // Even a subsequent successful server refresh cannot override the local withdrawal intent.
            let refreshed = try await reopened.retainCollectionSnapshot(Self.snapshot([plan]), replacing: stopped)
            #expect(refreshed.stoppedEnrollmentIDs == [id])
            #expect(refreshed.snapshot?.permitsHeartRateAcquisition == false)
            #expect(try #require(refreshed.snapshot).consentIDs(forHeartRateAt: Self.start).isEmpty)
            await reopened.close()
        }
    }

    @Test
    func stoppingBeforeFirstDiscoveryRemainsStickyAndDoesNotAuthorizeCollection() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let plan = Self.plan()
            let stopped = try await journal.stopCollection(for: #require(UUID(uuidString: plan.enrollmentId)))
            #expect(stopped.snapshot == nil)
            await #expect(throws: ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized) {
                try await journal.collectionCheckpoint(for: DeliveryFixture.sourceID, state: stopped)
            }
            let later = try await journal.retainCollectionSnapshot(Self.snapshot([plan]), replacing: stopped)
            #expect(later.snapshot?.permitsHeartRateAcquisition == false)
            let repeatStop = try await journal.stopCollection(for: #require(UUID(uuidString: plan.enrollmentId)))
            #expect(repeatStop.revision == later.revision)
        }
    }

    @Test
    func outOfOrderVersionsObservationsAndChangedPolicyCannotReplaceAcceptedAuthority() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let plan = Self.plan()
            let retained = try await journal.retainCollectionSnapshot(Self.snapshot([plan]), replacing: journal.collectionState())
            var olderVersion = plan, olderObservation = plan, changedPolicy = plan
            olderVersion.stateVersion -= 1
            olderObservation.asOf -= 1
            changedPolicy.windows[0].requirements[0].start -= 1
            for invalid in [olderVersion, olderObservation, changedPolicy] {
                await #expect(throws: DeliveryJournalError.staleCollectionState) {
                    try await journal.retainCollectionSnapshot(Self.snapshot([invalid]), replacing: retained)
                }
                #expect(try await journal.collectionState().revision == retained.revision)
            }
            var newer = plan
            newer.stateVersion += 1
            newer.asOf += 1
            let refreshed = try await journal.retainCollectionSnapshot(Self.snapshot([newer]), replacing: retained)
            await #expect(throws: DeliveryJournalError.staleCollectionState) {
                try await journal.retainCollectionSnapshot(Self.snapshot([plan]), replacing: retained)
            }
            #expect(try await journal.collectionState().revision == refreshed.revision)
        }
    }

    @Test(arguments: [true, false])
    func completeDiscoveryRemovalOrKnownWithdrawalCannotReviveOldPlans(removesEnrollment: Bool) async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let plan = Self.plan()
            let state = try await journal.retainCollectionSnapshot(Self.snapshot([plan]), replacing: journal.collectionState())
            var withdrawn = plan
            withdrawn.stateVersion += 1
            withdrawn.windows = []
            let stopped = try await journal.retainCollectionSnapshot(Self.snapshot(removesEnrollment ? [] : [withdrawn]), replacing: state)
            #expect(stopped.snapshot?.permitsHeartRateAcquisition == false)
            #expect(stopped.stoppedEnrollmentIDs == [try #require(UUID(uuidString: plan.enrollmentId))])
            var attemptedRevival = plan
            attemptedRevival.stateVersion += 2
            let refreshed = try await journal.retainCollectionSnapshot(Self.snapshot([attemptedRevival]), replacing: stopped)
            #expect(refreshed.snapshot?.permitsHeartRateAcquisition == false)
        }
    }

    @Test
    func capacityFailureRollsBackAuthorityAndLeavesExistingQueryUsable() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let plan = Self.plan()
            let retained = try await journal.retainCollectionSnapshot(Self.snapshot([plan]), replacing: journal.collectionState())
            let checkpoint = try await journal.collectionCheckpoint(for: DeliveryFixture.sourceID, state: retained)
            await journal.close()
            let bounded = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting, limits: .init(maximumBytes: 1))
            await #expect(throws: DeliveryJournalError.capacityExceeded) {
                try await bounded.retainCollectionSnapshot(Self.snapshot([plan, Self.plan()]), replacing: retained)
            }
            #expect(try await bounded.collectionState().revision == retained.revision)
            #expect(try await bounded.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
            await bounded.close()
        }
    }

    @Test
    func corruptRetainedAuthorityIsRefusedWithoutRecreatingOrLosingQueuedData() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let ids = try await DeliveryFixture.stage(journal, changes: ["preserved"])
            _ = try await journal.retainCollectionSnapshot(Self.snapshot([Self.plan()]), replacing: journal.collectionState())
            let connection = try DeliverySQLite(url: url)
            try connection.execute("UPDATE collection_state SET content = ?", [.blob(Data("{}".utf8))])
            connection.close()
            await #expect(throws: DeliveryJournalError.corruptJournal) { try await journal.collectionState() }
            #expect(try await journal.pendingDeliveryIDs() == ids)
        }
    }
}


extension ParticipantCollectionStateTests {
    private static func plan() -> Components.Schemas.ParticipantCollectionPlan {
        .init(enrollmentId: UUID().uuidString.lowercased(), stateVersion: 2, asOf: start.addingTimeInterval(10), windows: [
            .init(
                consentId: UUID().uuidString.lowercased(),
                publicationId: UUID().uuidString.lowercased(),
                revision: 1,
                start: start,
                requirements: [
                    .init(
                        profile: ParticipantCollectionSnapshot.heartRateProfile,
                        sourceKind: .participantApp,
                        start: start.addingTimeInterval(-15_552_000)
                    )
                ]
            )
        ])
    }

    private static func snapshot(_ plans: [Components.Schemas.ParticipantCollectionPlan]) throws -> ParticipantCollectionSnapshot {
        try ParticipantCollectionSnapshot(plans: plans, enrollmentIDs: plans.map { try #require(UUID(uuidString: $0.enrollmentId)) })
    }

    private func payloadCommitment(_ payload: EventDeliveryJournal.Payload) throws -> EventSubmissionCommitment {
        try TroveDeliveryContract.commitment(sourceID: DeliveryFixture.sourceID, originalBytes: payload.bytes, targets: payload.targets)
    }
}
