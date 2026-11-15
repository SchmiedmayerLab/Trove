//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPIClient


struct WorkoutRouteScopeTests {
    private static func plan(routes: Bool) -> Components.Schemas.ParticipantCollectionPlan {
        .init(
            enrollmentId: UUID().uuidString,
            studyId: UUID().uuidString,
            title: .init([.enUS: "Study"]),
            stateVersion: 1,
            asOf: Date(timeIntervalSinceReferenceDate: 200),
            windows: [
                .init(
                    consentId: UUID().uuidString,
                    publicationId: UUID().uuidString,
                    revision: 1,
                    start: Date(timeIntervalSinceReferenceDate: 100),
                    requirements: [
                        .init(
                            includeWorkoutRoutes: routes,
                            profile: CollectionObservationProfile.workout.rawValue,
                            sourceKind: .participantApp,
                            start: Date(timeIntervalSinceReferenceDate: 50)
                        )
                    ]
                )
            ]
        )
    }

    @Test
    func twoStudiesShareWorkoutDemandButOnlyOneReceivesRouteAuthority() throws {
        let plans = [Self.plan(routes: false), Self.plan(routes: true)]
        let snapshot = try ParticipantCollectionSnapshot(plans: plans, enrollmentIDs: plans.compactMap { UUID(uuidString: $0.enrollmentId) })
        let start = Date(timeIntervalSinceReferenceDate: 40), end = Date(timeIntervalSinceReferenceDate: 60)
        let workoutConsents = try snapshot.consentIDs(profile: .workout, start: start, end: end)
        #expect(Set(workoutConsents) == Set(plans.compactMap { UUID(uuidString: $0.windows[0].consentId) }))
        let routeConsents = try snapshot.consentIDs(profile: .workout, start: start, end: end, requiresWorkoutRoute: true)
        #expect(routeConsents == [try #require(UUID(uuidString: plans[1].windows[0].consentId))])
        let boundary = try snapshot.consentIDs(
            profile: .workout,
            start: start,
            end: Date(timeIntervalSinceReferenceDate: 50),
            requiresWorkoutRoute: true
        )
        #expect(boundary.isEmpty)
    }

    @Test
    func routeScopeChangesAreDetectedAndUnsupportedProfilesAreRejected() throws {
        let original = Self.plan(routes: false)
        let enrollmentID = try #require(UUID(uuidString: original.enrollmentId))
        let before = try ParticipantCollectionSnapshot(plans: [original], enrollmentIDs: [enrollmentID])
        var changed = original
        changed.windows[0].requirements[0].includeWorkoutRoutes = true
        let after = try ParticipantCollectionSnapshot(plans: [changed], enrollmentIDs: [enrollmentID])
        #expect(!before.hasSameAuthority(as: after))
        changed.windows[0].requirements[0].profile = CollectionObservationProfile.heartRate.rawValue
        #expect(throws: ParticipantCollectionSnapshot.CollectionError.unsupportedRequirement) {
            try ParticipantCollectionSnapshot(plans: [changed], enrollmentIDs: [enrollmentID])
        }
    }
}
