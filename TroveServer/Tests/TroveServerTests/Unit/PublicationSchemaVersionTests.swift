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


/// Policies accepted before requirement levels and unavailable requirements existed stay interpretable.
struct PublicationSchemaVersionTests {
    private static let studyID = UUID(uuidString: "6C2B1F0E-6E8B-4C33-9D0B-0D4C49A50A11")!  // swiftlint:disable:this force_unwrapping

    /// The exact archive form of a version 6 policy, as publications before requirement levels wrote it.
    private static let version6 = """
        {"collectionWindow":"retained-measurement-window","contractRevision":"8c18d9b8ba36eff3f6003c65cdc9cae74a6d3228",\
        "contractVersion":"0.8.2","enrollmentPeriod":{"calendar":"gregorian","timeZone":"UTC"},\
        "receivesDeviceUnitIdentifiers":false,"requirements":[{"includeWorkoutRoutes":false,\
        "profile":"https://grovealliance.org/fhir/mobile/StructureDefinition/grove-mobile-heart-rate","sourceKind":"participant-app"}],\
        "revision":1,"schemaVersion":6,"studyID":"6C2B1F0E-6E8B-4C33-9D0B-0D4C49A50A11","valueShape":"profiled-observation"}
        """

    @Test
    func versionSixPoliciesRemainInterpretable() throws {
        let policy = try JSONDecoder().decode(PublishedCollectionPolicy.self, from: Data(Self.version6.utf8))
        #expect(policy.schemaVersion == 6 && policy.unavailableRequirements.isEmpty)
        let requirements = try policy.validatedRequirements(studyID: Self.studyID, revision: 1)
        #expect(requirements.map(\.requirement) == [.required])
        let acceptedAt = Date(timeIntervalSince1970: 1_750_000_000)
        #expect(policy.permits(
            studyID: Self.studyID,
            revision: 1,
            profile: CollectionObservationProfile.heartRate.rawValue,
            sourceKind: .participantApp,
            effectiveAt: acceptedAt,
            consentAcceptedAt: acceptedAt
        ))
    }

    @Test
    func versionSixPoliciesCannotNameUnavailableRequirements() throws {
        var json = try #require(JSONSerialization.jsonObject(with: Data(Self.version6.utf8)) as? [String: Any])
        json["unavailableRequirements"] = json["requirements"]
        let policy = try JSONDecoder().decode(PublishedCollectionPolicy.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(throws: ServerError.self) { try policy.validatedRequirements(studyID: Self.studyID, revision: 1) }
    }

    @Test
    func currentPoliciesRecordUnavailableOptionalRequirementsAndGrantNone() throws {
        let available = CollectionRequirement(profile: CollectionObservationProfile.heartRate.rawValue, sourceKind: .participantApp)
        let unavailable = CollectionRequirement(
            profile: CollectionObservationProfile.heartRate.rawValue,
            sourceKind: .participantApp,
            sourceTypeIdentifier: "HKQuantityTypeIdentifierUnimplementedSource",
            requirement: .optional
        )
        let policy = try PublishedCollectionPolicy.compile(
            studyID: Self.studyID,
            revision: 2,
            requirements: [available],
            receivesDeviceUnitIdentifiers: false,
            unavailableRequirements: [unavailable]
        )
        let decoded = try JSONDecoder().decode(PublishedCollectionPolicy.self, from: policy.archiveBytes())
        #expect(decoded == policy && decoded.schemaVersion == PublishedCollectionPolicy.currentSchemaVersion)
        #expect(try decoded.validatedRequirements(studyID: Self.studyID, revision: 2) == [available])
        #expect(decoded.unavailableRequirements == [unavailable])

        let required = CollectionRequirement(
            profile: unavailable.profile,
            sourceKind: unavailable.sourceKind,
            sourceTypeIdentifier: unavailable.sourceTypeIdentifier,
            requirement: .required
        )
        #expect(throws: ServerError.self) {
            try PublishedCollectionPolicy.compile(
                studyID: Self.studyID,
                revision: 2,
                requirements: [available],
                receivesDeviceUnitIdentifiers: false,
                unavailableRequirements: [required]
            )
        }
        // An unsupported native source cannot be granted.
        #expect(throws: ServerError.self) {
            try PublishedCollectionPolicy.compile(
                studyID: Self.studyID, revision: 2, requirements: [unavailable], receivesDeviceUnitIdentifiers: false
            )
        }
    }

    @Test
    func draftRequirementsMayNameUnimplementedNativeSources() throws {
        let unsupported = CollectionRequirement(
            profile: CollectionObservationProfile.heartRate.rawValue,
            sourceKind: .participantApp,
            sourceTypeIdentifier: "HKQuantityTypeIdentifierUnimplementedSource"
        )
        #expect(!unsupported.hasSupportedNativeSource)
        try CollectionRequirement.validate([unsupported], requiringSupportedSources: false)
        #expect(throws: ServerError.self) { try CollectionRequirement.validate([unsupported]) }
        let unknownProfile = CollectionRequirement(profile: "https://example.org/unknown", sourceKind: .participantApp)
        #expect(throws: ServerError.self) { try CollectionRequirement.validate([unknownProfile], requiringSupportedSources: false) }
    }
}
