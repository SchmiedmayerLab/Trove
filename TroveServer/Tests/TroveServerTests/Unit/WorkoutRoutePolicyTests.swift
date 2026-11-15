//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPIServer
@testable import TroveServer


struct WorkoutRoutePolicyTests {
    private let workout = CollectionObservationProfile.workout.rawValue
    private let acceptedAt = Date(timeIntervalSinceReferenceDate: 100)

    @Test(arguments: [false, true])
    func acceptedRouteOptionSurvivesArchiveAndScopeEncoding(includesRoutes: Bool) throws {
        let studyID = UUID()
        let requirement = CollectionRequirement(profile: workout, sourceKind: .participantApp, includeWorkoutRoutes: includesRoutes)
        let policy = try PublishedCollectionPolicy.compile(studyID: studyID, revision: 1, requirements: [requirement])
        let scope = try AcceptedCollectionScope(requirements: [requirement], acceptedAt: acceptedAt)
        let retained = try JSONDecoder().decode(AcceptedCollectionScope.self, from: JSONEncoder().encode(scope))
        let archived = try #require(JSONSerialization.jsonObject(with: policy.archiveBytes()) as? [String: Any])
        let requirements = try #require(archived["requirements"] as? [[String: Any]])
        #expect(requirements.first?["includeWorkoutRoutes"] as? Bool == includesRoutes)
        #expect(retained.requirements.first?.includeWorkoutRoutes == includesRoutes)
        #expect(policy.permits(
            studyID: studyID,
            revision: 1,
            profile: workout,
            sourceKind: .participantApp,
            effectiveAt: acceptedAt,
            consentAcceptedAt: acceptedAt,
            effectiveEnd: acceptedAt.addingTimeInterval(60),
            scope: retained
        ))
        #expect(policy.permits(
            studyID: studyID,
            revision: 1,
            profile: workout,
            sourceKind: .participantApp,
            effectiveAt: acceptedAt,
            consentAcceptedAt: acceptedAt,
            effectiveEnd: acceptedAt.addingTimeInterval(60),
            scope: retained,
            requiresWorkoutRoute: true
        ) == includesRoutes)
        let wire = Components.Schemas.CollectionRequirement(requirement)
        #expect(CollectionRequirement(wire) == requirement)
    }

    @Test
    func routePermissionCannotBeReconstructedFromWorkoutConsent() throws {
        let studyID = UUID()
        let summaries = CollectionRequirement(profile: workout, sourceKind: .participantApp)
        let routes = CollectionRequirement(profile: workout, sourceKind: .participantApp, includeWorkoutRoutes: true)
        let policy = try PublishedCollectionPolicy.compile(studyID: studyID, revision: 2, requirements: [routes])
        let olderScope = try AcceptedCollectionScope(requirements: [summaries], acceptedAt: acceptedAt)
        for scope in [olderScope, nil] {
            #expect(throws: ServerError.self) {
                try policy.resolvedRequirements(studyID: studyID, revision: 2, acceptedAt: acceptedAt, scope: scope, adoptionEnd: nil)
            }
        }
    }

    @Test(arguments: [CollectionObservationProfile.heartRate, .sleepStage])
    func routesRequireTheWorkoutProfile(profile: CollectionObservationProfile) throws {
        #expect(throws: ServerError.self) {
            try PublishedCollectionPolicy.compile(studyID: UUID(), revision: 1, requirements: [
                .init(profile: profile.rawValue, sourceKind: .participantApp, includeWorkoutRoutes: true)
            ])
        }
    }

    @Test(arguments: ["en-US", "de-DE"])
    func consentDescribesTheAcceptedRouteChoice(locale: String) throws {
        let included = try CollectionScopePresentation.markdown(requirements: [
            .init(profile: workout, sourceKind: .participantApp, includeWorkoutRoutes: true)
        ], locale: locale)
        let excluded = try CollectionScopePresentation.markdown(requirements: [
            .init(profile: workout, sourceKind: .participantApp)
        ], locale: locale)
        #expect(included != excluded)
        #expect(included.contains(locale == "de-DE" ? "Genaue Standortverläufe" : "Precise location routes"))
        #expect(excluded.contains(locale == "de-DE" ? "nicht erfasst" : "not collected for this study"))
    }
}
