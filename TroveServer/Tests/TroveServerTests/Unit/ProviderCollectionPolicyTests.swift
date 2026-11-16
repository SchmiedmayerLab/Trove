// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import TroveAPITypes
@testable import TroveServer


struct ProviderCollectionPolicyTests {
    @Test
    func registrationIsPartOfTheRetainedAuthorityAndUniquenessKey() throws {
        let first = UUID(), second = UUID(), study = UUID(), accepted = Date(timeIntervalSince1970: 1_750_000_000)
        let profile = CollectionObservationProfile.bodyWeight.rawValue
        let requirements: [CollectionRequirement] = [
            .init(profile: profile, sourceKind: .participantApp),
            .init(profile: profile, sourceKind: .serverWorker, providerRegistrationID: first, sourceTypeIdentifier: "getmeas:1"),
            .init(profile: profile, sourceKind: .serverWorker, providerRegistrationID: second, sourceTypeIdentifier: "getmeas:1")
        ]
        let policy = try PublishedCollectionPolicy.compile(studyID: study, revision: 1, requirements: requirements)
        let scope = try AcceptedCollectionScope(requirements: requirements, acceptedAt: accepted)
        let restored = try JSONDecoder().decode(AcceptedCollectionScope.self, from: JSONEncoder().encode(scope))
        #expect(restored == scope && restored.requirements.map(\.providerRegistrationID) == [nil, first, second])
        for identifier in [first, second] {
            #expect(policy.permits(
                studyID: study,
                revision: 1,
                profile: profile,
                sourceKind: .serverWorker,
                effectiveAt: accepted,
                consentAcceptedAt: accepted,
                scope: restored,
                providerRegistrationID: identifier,
                sourceTypeIdentifier: "getmeas:1"
            ))
        }
        for identifier in [UUID?.none, UUID()] {
            #expect(!policy.permits(
                studyID: study,
                revision: 1,
                profile: profile,
                sourceKind: .serverWorker,
                effectiveAt: accepted,
                consentAcceptedAt: accepted,
                scope: restored,
                providerRegistrationID: identifier,
                sourceTypeIdentifier: "getmeas:1"
            ))
        }
        #expect(throws: (any Error).self) { try CollectionRequirement.validate(requirements + [requirements[1]]) }
    }

    @Test
    func nativeAndWorkerAuthorityCannotBeInterchanged() throws {
        let profile = CollectionObservationProfile.bodyWeight.rawValue
        for requirement in [
            CollectionRequirement(profile: profile, sourceKind: .serverWorker),
            .init(profile: profile, sourceKind: .participantApp, providerRegistrationID: UUID()),
            .init(
                profile: CollectionObservationProfile.workout.rawValue,
                sourceKind: .serverWorker,
                includeWorkoutRoutes: true,
                providerRegistrationID: UUID(),
                sourceTypeIdentifier: "workout"
            )
        ] {
            #expect(throws: (any Error).self) { try CollectionRequirement.validate([requirement]) }
        }
    }
}
