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


struct ParticipantCollectionRefreshTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 100)

    @Test
    func completeDiscoveryRetainsEveryPlanAndIncompleteRefreshCannotBroadenIt() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let first = Self.plan(), second = Self.plan()
            let transport = CollectionRefreshTransport(enrollments: [Self.enrollment(first)], plans: [first])
            let before = try await Self.refresh(journal, transport: transport)
            #expect(before.snapshot?.permitsHeartRateAcquisition == true)
            #expect(await transport.paths.count == 2)
            var broader = first
            broader.stateVersion += 1
            broader.windows[0].requirements[0].start -= 1000
            let incomplete = CollectionRefreshTransport(
                enrollments: [Self.enrollment(broader), Self.enrollment(second)], plans: [broader, second], failingRequest: 3
            )
            await #expect(throws: ParticipantCollectionRefresh.RefreshError.unavailable) {
                try await Self.refresh(journal, transport: incomplete)
            }
            #expect(try await journal.collectionState().revision == before.revision)
            #expect(try await journal.collectionState().snapshot?.heartRateQueryStart == Self.start)
            #expect(await incomplete.paths.count == 3)
        }
    }

    @Test(arguments: [true, false])
    func knownWithdrawalIsRetainedEvenWhenAnotherPlanRequestFails(inEnrollmentList: Bool) async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let first = Self.plan(), second = Self.plan()
            let initial = CollectionRefreshTransport(enrollments: [Self.enrollment(first), Self.enrollment(second)], plans: [first, second])
            let before = try await Self.refresh(journal, transport: initial)
            let checkpoint = try await journal.collectionCheckpoint(for: DeliveryFixture.sourceID, state: before)
            var withdrawnPlan = first
            withdrawnPlan.stateVersion += 1
            withdrawnPlan.windows = []
            var withdrawnEnrollment = Self.enrollment(first)
            if inEnrollmentList {
                withdrawnEnrollment.withdrawnAt = Self.start
                withdrawnEnrollment.stateVersion += 1
            }
            let transport = CollectionRefreshTransport(
                enrollments: [withdrawnEnrollment, Self.enrollment(second)],
                plans: [withdrawnPlan, second],
                failingRequest: inEnrollmentList ? 2 : 3
            )
            await #expect(throws: ParticipantCollectionRefresh.RefreshError.unavailable) {
                try await Self.refresh(journal, transport: transport)
            }
            let after = try await journal.collectionState()
            #expect(after.stoppedEnrollmentIDs == [try #require(UUID(uuidString: first.enrollmentId))])
            #expect(try #require(after.snapshot).consentIDs(forHeartRateAt: Self.start) == [#require(UUID(uuidString: second.windows[0].consentId))])
            await #expect(throws: DeliveryJournalError.staleCheckpoint) {
                try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: [])
            }
        }
    }

    @Test
    func localWithdrawalDuringDiscoveryRefusesLateResponse() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let plan = Self.plan()
            let id = try #require(UUID(uuidString: plan.enrollmentId))
            let transport = CollectionRefreshTransport(enrollments: [Self.enrollment(plan)], plans: [plan]) { request in
                if request == 1 { _ = try await journal.stopCollection(for: id) }
            }
            await #expect(throws: DeliveryJournalError.staleCollectionState) {
                try await Self.refresh(journal, transport: transport)
            }
            let after = try await journal.collectionState()
            #expect(after.snapshot == nil)
            #expect(after.stoppedEnrollmentIDs == [id])
            #expect(await transport.paths.count == 1)
        }
    }

    @Test
    func concurrentAdoptionCannotBeRemovedByEarlierEnrollmentDiscovery() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let first = Self.plan(), second = Self.plan()
            let snapshot = try ParticipantCollectionSnapshot(
                plans: [first, second], enrollmentIDs: [first, second].map { try #require(UUID(uuidString: $0.enrollmentId)) }
            )
            let transport = CollectionRefreshTransport(enrollments: [Self.enrollment(first)], plans: [first]) { request in
                if request == 2 {
                    try await journal.retainCollectionSnapshot(snapshot, replacing: journal.collectionState())
                }
            }
            await #expect(throws: DeliveryJournalError.staleCollectionState) {
                try await Self.refresh(journal, transport: transport)
            }
            let after = try await journal.collectionState()
            #expect(after.stoppedEnrollmentIDs.isEmpty)
            #expect(try #require(after.snapshot).consentIDs(forHeartRateAt: Self.start).count == 2)
        }
    }

    @Test(arguments: [1, 2])
    func accountChangeBeforeEitherReplyCannotRetainNewAuthority(requestNumber: Int) async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let plan = Self.plan()
            let session = DeliveryTestSession()
            let transport = CollectionRefreshTransport(enrollments: [Self.enrollment(plan)], plans: [plan]) { request in
                if request == requestNumber { await session.invalidate() }
            }
            await #expect(throws: ParticipantCollectionRefresh.RefreshError.authenticationRequired) {
                try await Self.refresh(journal, transport: transport, session: session)
            }
            let after = try await journal.collectionState()
            #expect(after.snapshot == nil)
            #expect(await transport.paths.count == requestNumber)
        }
    }

    @Test
    func duplicateDiscoveryAndStalePlanVersionDoNotChangeRetainedState() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let plan = Self.plan()
            let enrollment = Self.enrollment(plan)
            let duplicate = CollectionRefreshTransport(enrollments: [enrollment, enrollment], plans: [plan])
            await #expect(throws: ParticipantCollectionSnapshot.CollectionError.invalidPlan) {
                try await Self.refresh(journal, transport: duplicate)
            }
            #expect(await duplicate.paths.count == 1)
            var stale = plan
            stale.stateVersion -= 1
            let transport = CollectionRefreshTransport(enrollments: [enrollment], plans: [stale])
            await #expect(throws: DeliveryJournalError.staleCollectionState) {
                try await Self.refresh(journal, transport: transport)
            }
            let after = try await journal.collectionState()
            #expect(after.snapshot == nil)
        }
    }
}


extension ParticipantCollectionRefreshTests {
    private static func plan() -> Components.Schemas.ParticipantCollectionPlan {
        .init(enrollmentId: UUID().uuidString.lowercased(), stateVersion: 2, asOf: start.addingTimeInterval(10), windows: [
            .init(
                consentId: UUID().uuidString.lowercased(),
                publicationId: UUID().uuidString.lowercased(),
                revision: 1,
                start: start,
                requirements: [.init(profile: ParticipantCollectionSnapshot.heartRateProfile, sourceKind: .participantApp, start: start)]
            )
        ])
    }

    private static func enrollment(_ plan: Components.Schemas.ParticipantCollectionPlan) -> Components.Schemas.EnrollmentResponse {
        .init(
            id: plan.enrollmentId,
            studyId: UUID().uuidString.lowercased(),
            participantId: DeliveryFixture.scope.subject,
            currentRevision: 1,
            stateVersion: plan.stateVersion,
            enrolledAt: Self.start
        )
    }

    private static func refresh(
        _ journal: EventDeliveryJournal, transport: CollectionRefreshTransport, session: DeliveryTestSession = .init()
    ) async throws -> ParticipantCollectionState {
        let client = Client(serverURL: try #require(URL(string: DeliveryFixture.scope.backend)), configuration: .trove, transport: transport)
        return try await ParticipantCollectionRefresh.refresh(journal: journal, scope: DeliveryFixture.scope, client: client) {
            try await session.validate()
        }
    }
}
