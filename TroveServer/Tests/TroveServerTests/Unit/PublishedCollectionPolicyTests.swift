//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPITypes
@testable import TroveServer


struct PublishedCollectionPolicyTests {
    private static let studyID = UUID()
    private static let acceptedAt = Date(timeIntervalSince1970: 1_750_000_000)
    private static let requirement = CollectionRequirement(profile: CollectionRequirement.supportedProfile, sourceKind: .participantApp)

    @Test
    func publicationDeclaresThePinnedValidatorContract() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let bytes = try Data(contentsOf: root.appendingPathComponent("TroveInfrastructure/validator/manifest.json"))
        let manifest = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let release = try #require(manifest["guideRelease"] as? [String: Any])
        let policy = try PublishedCollectionPolicy.compile(studyID: Self.studyID, revision: 2, requirements: [Self.requirement])
        #expect(policy.contractVersion == release["tag"] as? String)
        #expect(policy.contractRevision == manifest["contractRevision"] as? String)
    }

    @Test(arguments: [-1.0, 0, 1])
    func pointCollectionStartsAtExactConsentAcceptance(offset: Double) throws {
        let policy = try PublishedCollectionPolicy.compile(studyID: Self.studyID, revision: 2, requirements: [Self.requirement])
        #expect(policy.permits(
            studyID: Self.studyID,
            revision: 2,
            profile: Self.requirement.profile,
            sourceKind: .participantApp,
            effectiveAt: Self.acceptedAt.addingTimeInterval(offset),
            consentAcceptedAt: Self.acceptedAt
        ) == (offset >= 0))
    }

    @Test(arguments: ["study", "revision", "profile", "empty"])
    func authorizationDoesNotGeneralizeBeyondPublishedRequirement(mismatch: String) throws {
        let policy = try PublishedCollectionPolicy.compile(
            studyID: Self.studyID, revision: 2, requirements: mismatch == "empty" ? [] : [Self.requirement]
        )
        #expect(!policy.permits(
            studyID: mismatch == "study" ? UUID() : Self.studyID,
            revision: mismatch == "revision" ? 1 : 2,
            profile: mismatch == "profile" ? "HKQuantityTypeIdentifierHeartRate" : Self.requirement.profile,
            sourceKind: .participantApp,
            effectiveAt: Self.acceptedAt,
            consentAcceptedAt: Self.acceptedAt
        ))
    }

    /// Heart rate may be a point or a period, so a strictly instantaneous profile exercises the refusal.
    @Test(arguments: [nil, TimeInterval(60)])
    func pointPolicyDoesNotDiscardAnIntervalEnd(duration: TimeInterval?) throws {
        let profile = CollectionObservationProfile.bodyWeight.rawValue
        let policy = try PublishedCollectionPolicy.compile(
            studyID: Self.studyID, revision: 2, requirements: [.init(profile: profile, sourceKind: .participantApp)]
        )
        #expect(policy.permits(
            studyID: Self.studyID,
            revision: 2,
            profile: profile,
            sourceKind: .participantApp,
            effectiveAt: Self.acceptedAt,
            consentAcceptedAt: Self.acceptedAt,
            effectiveEnd: duration.map(Self.acceptedAt.addingTimeInterval)
        ) == (duration == nil))
    }

    @Test(arguments: ["contractVersion", "contractRevision", "valueShape", "collectionWindow", "schemaVersion", "legacy-contract"])
    func unknownPersistedPolicyContractFailsClosed(field: String) throws {
        let policy = try PublishedCollectionPolicy.compile(studyID: Self.studyID, revision: 2, requirements: [Self.requirement])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as? [String: Any])
        if field == "legacy-contract" {
            json["contractVersion"] = "0.6.0"
            json["contractRevision"] = "444e06fb25680c3af29e5d3ccbebeb0249be7318"
        } else {
            json[field] = field == "schemaVersion" ? Int.max : "unsupported"
        }
        let altered = try JSONDecoder().decode(PublishedCollectionPolicy.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(throws: ServerError.self) {
            try altered.validatedRequirements(studyID: Self.studyID, revision: 2)
        }
        #expect(!altered.permits(
            studyID: Self.studyID,
            revision: 2,
            profile: Self.requirement.profile,
            sourceKind: .participantApp,
            effectiveAt: Self.acceptedAt,
            consentAcceptedAt: Self.acceptedAt
        ))
    }

    @Test(arguments: ["duplicate", "unsupported"])
    func unsupportedOrDuplicateRequirementsCannotCompile(failure: String) {
        let requirements: [CollectionRequirement] = failure == "duplicate" ? [Self.requirement, Self.requirement]
            : [.init(profile: "https://example.org/unsupported-profile", sourceKind: .participantApp)]
        #expect(throws: ServerError.self) {
            try PublishedCollectionPolicy.compile(studyID: Self.studyID, revision: 1, requirements: requirements)
        }
    }
}


extension PublishedCollectionPolicyTests {
    @Test(arguments: [(-60.0, 60.0, true), (-60, 0, false), (60, 120, true), (120, 180, false), (-60, 180, true)])
    func sleepPolicyIncludesWholeOverlappingIntervals(start: Double, end: Double, included: Bool) throws {
        let sleep = CollectionRequirement(profile: CollectionObservationProfile.sleepStage.rawValue, sourceKind: .participantApp)
        let policy = try PublishedCollectionPolicy.compile(studyID: Self.studyID, revision: 2, requirements: [Self.requirement, sleep])
        #expect(policy.permits(
            studyID: Self.studyID,
            revision: 2,
            profile: sleep.profile,
            sourceKind: .participantApp,
            effectiveAt: Self.acceptedAt.addingTimeInterval(start),
            consentAcceptedAt: Self.acceptedAt,
            effectiveEnd: Self.acceptedAt.addingTimeInterval(end),
            adoptionEnd: Self.acceptedAt.addingTimeInterval(120)
        ) == included)
        #expect(!policy.permits(
            studyID: Self.studyID,
            revision: 2,
            profile: sleep.profile,
            sourceKind: .participantApp,
            effectiveAt: Self.acceptedAt,
            consentAcceptedAt: Self.acceptedAt
        ))
    }

    @Test
    func consentDescribesCompleteSleepIntervalsInBothSupportedLanguages() throws {
        let sleep = CollectionRequirement(profile: CollectionObservationProfile.sleepStage.rawValue, sourceKind: .participantApp)
        let english = try CollectionScopePresentation.markdown(requirements: [Self.requirement, sleep], locale: "en-US")
        let german = try CollectionScopePresentation.markdown(requirements: [sleep], locale: "de-DE")
        #expect(english.contains("Heart rate") && english.contains("Sleep stages"))
        #expect(english.contains("collected in full") && english.contains("start before it or end after it"))
        #expect(german.contains("Schlafphasen") && german.contains("vollständig") && german.contains("überlappen"))
    }
}
