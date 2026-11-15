// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import TroveAPITypes
@testable import TroveServer


struct BodyWeightPolicyTests {
    @Test
    func bodyWeightIsAnExplicitPointPermissionWithTruthfulConsentText() throws {
        let studyID = UUID(), accepted = Date(timeIntervalSince1970: 1_750_000_000)
        let requirement = CollectionRequirement(profile: CollectionObservationProfile.bodyWeight.rawValue, sourceKind: .participantApp)
        let policy = try PublishedCollectionPolicy.compile(studyID: studyID, revision: 1, requirements: [requirement])
        #expect(policy.permits(
            studyID: studyID,
            revision: 1,
            profile: requirement.profile,
            sourceKind: .participantApp,
            effectiveAt: accepted,
            consentAcceptedAt: accepted
        ))
        #expect(!policy.permits(
            studyID: studyID,
            revision: 1,
            profile: requirement.profile,
            sourceKind: .participantApp,
            effectiveAt: accepted.addingTimeInterval(-1),
            consentAcceptedAt: accepted
        ))
        #expect(!policy.permits(
            studyID: studyID,
            revision: 1,
            profile: requirement.profile,
            sourceKind: .participantApp,
            effectiveAt: accepted,
            consentAcceptedAt: accepted,
            effectiveEnd: accepted.addingTimeInterval(60)
        ))
        #expect(!policy.permits(
            studyID: studyID,
            revision: 1,
            profile: CollectionObservationProfile.heartRate.rawValue,
            sourceKind: .participantApp,
            effectiveAt: accepted,
            consentAcceptedAt: accepted
        ))
        let english = try CollectionScopePresentation.markdown(requirements: [requirement], locale: "en-US")
        let german = try CollectionScopePresentation.markdown(requirements: [requirement], locale: "de-DE")
        #expect(english.contains("Body weight") && !english.contains("Heart rate") && !english.contains("overlap"))
        #expect(german.contains("Körpergewicht") && !german.contains("Herzfrequenz"))
    }

    @Test
    func addedBodyWeightDoesNotAdmitUnknownProfilesOrWorkoutRouteScope() {
        #expect(throws: (any Error).self) {
            try CollectionRequirement.validate([
                .init(profile: "https://grovealliance.org/fhir/mobile/StructureDefinition/grove-mobile-unknown-measurement", sourceKind: .participantApp)
            ])
        }
        #expect(throws: (any Error).self) {
            try CollectionRequirement.validate([
                .init(profile: CollectionObservationProfile.bodyWeight.rawValue, sourceKind: .participantApp, includeWorkoutRoutes: true)
            ])
        }
    }
}
