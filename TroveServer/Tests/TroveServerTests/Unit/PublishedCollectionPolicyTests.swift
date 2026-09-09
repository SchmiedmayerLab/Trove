//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import TroveServer


struct PublishedCollectionPolicyTests {
    private static let studyID = UUID()
    private static let acceptedAt = Date(timeIntervalSince1970: 1_750_000_000)
    private static let requirement = CollectionRequirement(profile: CollectionRequirement.supportedProfile, sourceKind: .participantApp)

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

    @Test(arguments: ["contractVersion", "contractRevision", "valueShape", "collectionWindow", "schemaVersion"])
    func unknownPersistedPolicyContractFailsClosed(field: String) throws {
        let policy = try PublishedCollectionPolicy.compile(studyID: Self.studyID, revision: 2, requirements: [Self.requirement])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as? [String: Any])
        json[field] = field == "schemaVersion" ? 2 : "unsupported"
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
