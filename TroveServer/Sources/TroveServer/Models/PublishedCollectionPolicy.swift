//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


struct CollectionRequirement: Codable, Sendable, Hashable {
    /// Receiver capability, not a duplicate measurement catalog or substitute for IG validation.
    /// Grove FHIR 0.6.0: mobile/input/fsh/generated-measurement-profiles.fsh, GroveMobileHeartRate.
    static let supportedProfile = "https://grovealliance.org/fhir/mobile/StructureDefinition/grove-mobile-heart-rate"

    let profile: String
    let sourceKind: SourceKind

    static func validate(_ requirements: [Self]) throws {
        guard requirements.count <= 1, requirements.allSatisfy({ $0.profile == supportedProfile }) else {
            throw ServerError.badRequest("Collection requirements contain duplicate or unsupported receiver capabilities")
        }
    }
}


/// Researcher-selected collection authority captured with the exact published archive.
/// It does not establish participant identity, source ownership, consent, or active enrollment.
struct PublishedCollectionPolicy: Codable, Sendable, Hashable {
    static let filename = "collection-policy.json"

    let schemaVersion: Int
    let contractVersion: String
    let contractRevision: String
    let studyID: UUID
    let revision: Int
    let valueShape: String
    let collectionWindow: String
    let requirements: [CollectionRequirement]

    static func compile(studyID: UUID, revision: Int, requirements: [CollectionRequirement]) throws -> Self {
        guard revision > 0 else { throw ServerError.badRequest("Collection policy revision must be positive") }
        try CollectionRequirement.validate(requirements)
        return Self(
            schemaVersion: 1,
            contractVersion: "0.6.0",
            contractRevision: "444e06fb25680c3af29e5d3ccbebeb0249be7318",
            studyID: studyID,
            revision: revision,
            valueShape: "point-quantity",
            collectionWindow: "consent-forward",
            requirements: requirements
        )
    }

    /// Unknown policy fails; an empty array explicitly means no collection.
    func validatedRequirements(studyID: UUID, revision: Int) throws -> [CollectionRequirement] {
        guard schemaVersion == 1, contractVersion == "0.6.0", contractRevision == "444e06fb25680c3af29e5d3ccbebeb0249be7318",
              self.studyID == studyID, self.revision == revision,
              revision > 0, valueShape == "point-quantity", collectionWindow == "consent-forward",
              requirements.count <= 1, requirements.allSatisfy({ $0.profile == CollectionRequirement.supportedProfile }) else {
            throw ServerError.internalServerError("Exact collection policy is unavailable")
        }
        return requirements
    }

    // Call only for an IG-validated point Quantity after resolving active server-owned authority.
    // swiftlint:disable:next function_parameter_count
    func permits(
        studyID: UUID,
        revision: Int,
        profile: String,
        sourceKind: SourceKind,
        effectiveAt: Date,
        consentAcceptedAt: Date
    ) -> Bool {
        guard let requirements = try? validatedRequirements(studyID: studyID, revision: revision),
              effectiveAt.timeIntervalSinceReferenceDate.isFinite, consentAcceptedAt.timeIntervalSinceReferenceDate.isFinite,
              effectiveAt >= consentAcceptedAt else { return false }
        return requirements.contains { $0.profile == profile && $0.sourceKind == sourceKind }
    }
}
