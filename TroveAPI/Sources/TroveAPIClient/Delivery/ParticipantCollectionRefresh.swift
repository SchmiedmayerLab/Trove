//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPITypes


/// Complete enrollment discovery at a lifecycle boundary, separate from bounded offline acquisition.
/// A failed refresh preserves accepted plans; known withdrawals are retained even if another request fails.
public enum ParticipantCollectionRefresh {
    public enum RefreshError: Error, Equatable {
        case authenticationRequired
        case unavailable
    }

    /// Fetch all active plans with the captured session, then atomically replace the retained observation.
    public static func refresh(
        journal: EventDeliveryJournal,
        scope: DeliveryScope,
        client: any APIProtocol,
        validateSession: @Sendable () async throws -> Void
    ) async throws -> ParticipantCollectionState {
        guard journal.scope == scope else { throw DeliveryJournalError.wrongScope }
        try await checkSession(validateSession)
        var expected = try await journal.collectionState()
        let enrollments = try await enrollments(client)
        try await checkSession(validateSession)
        let identifiers = try enrollmentIDs(enrollments)
        let withdrawn = Set(zip(enrollments, identifiers).filter { $0.0.withdrawnAt != nil }.map(\.1))
        expected = try await journal.stopCollection(for: withdrawn, replacing: expected)
        var plans: [Components.Schemas.ParticipantCollectionPlan] = []
        for (enrollment, id) in zip(enrollments, identifiers) where enrollment.withdrawnAt == nil {
            try await checkSession(validateSession)
            let plan = try await plan(id, client: client)
            try await checkSession(validateSession)
            _ = try ParticipantCollectionSnapshot(plans: [plan], enrollmentIDs: [id])
            guard plan.stateVersion >= enrollment.stateVersion,
                  UUID(uuidString: plan.studyId) == UUID(uuidString: enrollment.studyId), plan.endsAt == enrollment.endsAt else {
                throw DeliveryJournalError.staleCollectionState
            }
            if let previous = expected.snapshot?.plans.first(where: { UUID(uuidString: $0.enrollmentId) == id }),
               !previous.windows.isEmpty, plan.windows.isEmpty {
                guard plan.stateVersion > previous.stateVersion, plan.asOf >= previous.asOf else {
                    throw DeliveryJournalError.staleCollectionState
                }
                expected = try await journal.stopCollection(for: [id], replacing: expected)
            }
            plans.append(plan)
        }
        let activeIDs = zip(enrollments, identifiers).filter { $0.0.withdrawnAt == nil }.map(\.1)
        let snapshot = try ParticipantCollectionSnapshot(plans: plans, enrollmentIDs: activeIDs)
        try await checkSession(validateSession)
        let retained = try await journal.retainCollectionSnapshot(snapshot, replacing: expected)
        try await checkSession(validateSession)
        return retained
    }

    private static func enrollmentIDs(_ enrollments: [Components.Schemas.EnrollmentResponse]) throws -> [UUID] {
        guard enrollments.count <= 128 else { throw ParticipantCollectionSnapshot.CollectionError.invalidPlan }
        let ids = try enrollments.map { enrollment in
            guard let id = UUID(uuidString: enrollment.id), enrollment.stateVersion > 0 else {
                throw ParticipantCollectionSnapshot.CollectionError.invalidPlan
            }
            return id
        }
        guard Set(ids).count == ids.count else { throw ParticipantCollectionSnapshot.CollectionError.invalidPlan }
        return ids
    }

    private static func enrollments(_ client: any APIProtocol) async throws -> [Components.Schemas.EnrollmentResponse] {
        do {
            switch try await client.getParticipantEnrollments(.init()) {
            case .ok(let response): return try response.body.json
            case .unauthorized: throw RefreshError.authenticationRequired
            default: throw RefreshError.unavailable
            }
        } catch {
            try Task.checkCancellation()
            throw error as? RefreshError ?? .unavailable
        }
    }

    private static func plan(_ id: UUID, client: any APIProtocol) async throws -> Components.Schemas.ParticipantCollectionPlan {
        do {
            switch try await client.getParticipantCollectionPlan(.init(path: .init(enrollmentId: id.uuidString.lowercased()))) {
            case .ok(let response): return try response.body.json
            case .unauthorized: throw RefreshError.authenticationRequired
            default: throw RefreshError.unavailable
            }
        } catch {
            try Task.checkCancellation()
            throw error as? RefreshError ?? .unavailable
        }
    }

    private static func checkSession(_ validate: @Sendable () async throws -> Void) async throws {
        try Task.checkCancellation()
        do {
            try await validate()
        } catch {
            try Task.checkCancellation()
            throw RefreshError.authenticationRequired
        }
        try Task.checkCancellation()
    }
}
