//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPITypes


struct CollectionRequirement: Codable, Sendable, Hashable {
    /// Receiver capability, not a duplicate measurement catalog or substitute for IG validation.
    /// Grove FHIR 0.8.0: mobile/input/fsh/generated-measurement-profiles.fsh, GroveMobileHeartRate.
    static let supportedProfile = "https://grovealliance.org/fhir/mobile/StructureDefinition/grove-mobile-heart-rate"

    let profile: String
    let sourceKind: SourceKind
    let measurementWindow: CollectionMeasurementWindow?

    init(profile: String, sourceKind: SourceKind, measurementWindow: CollectionMeasurementWindow? = nil) {
        self.profile = profile
        self.sourceKind = sourceKind
        self.measurementWindow = measurementWindow
    }

    static func validate(_ requirements: [Self]) throws {
        guard requirements.count <= 1, requirements.allSatisfy({ $0.profile == supportedProfile }) else {
            throw ServerError.badRequest("Collection requirements contain duplicate or unsupported receiver capabilities")
        }
        for requirement in requirements { try requirement.measurementWindow?.validate() }
    }
}


/// Researcher-selected collection authority captured with the exact published archive.
/// It does not establish participant identity, source ownership, consent, or active enrollment.
struct PublishedCollectionPolicy: Codable, Sendable, Hashable {
    struct ResolvedRequirement: Sendable {
        let profile: String
        let sourceKind: SourceKind
        let start: Date
        let end: Date?

        func contains(_ instant: Date) -> Bool {
            CollectionMeasurementWindow.valid(instant) && instant >= start && (end.map { instant < $0 } ?? true)
        }
    }

    private static var missingScope: ServerError { .internalServerError("Exact accepted collection scope is unavailable") }

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
            schemaVersion: 2,
            contractVersion: FHIRValidationClient.contractVersion,
            contractRevision: FHIRValidationClient.contractRevision,
            studyID: studyID,
            revision: revision,
            valueShape: "point-quantity",
            collectionWindow: "retained-measurement-window",
            requirements: requirements
        )
    }

    private static func validate(_ retained: ResolvedCollectionWindow, for requirement: CollectionRequirement, acceptedAt: Date) throws {
        guard retained.end == requirement.measurementWindow?.end else { throw missingScope }
        switch requirement.measurementWindow?.start {
        case .none:
            guard retained.start == nil else { throw missingScope }
        case .oldestSample:
            guard retained.start == CollectionMeasurementWindow.earliest else { throw missingScope }
        case .absolute(let absolute):
            guard retained.start == absolute.date else { throw missingScope }
        case .last:
            guard let start = retained.start, start < acceptedAt else { throw missingScope }
        }
    }

    /// The public archive uses RFC 3339 at the same precision as the API, independent of database JSON encoding.
    func archiveBytes() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            try value.encode(TroveDateTranscoder().encode(date))
        }
        return try encoder.encode(self)
    }

    /// Unknown policy fails; an empty array explicitly means no collection.
    func validatedRequirements(studyID: UUID, revision: Int) throws -> [CollectionRequirement] {
        guard schemaVersion == 2, contractVersion == FHIRValidationClient.contractVersion,
              contractRevision == FHIRValidationClient.contractRevision,
              self.studyID == studyID, self.revision == revision,
              revision > 0, valueShape == "point-quantity", collectionWindow == "retained-measurement-window",
              requirements.count <= 1, requirements.allSatisfy({ $0.profile == CollectionRequirement.supportedProfile }) else {
            throw ServerError.internalServerError("Exact collection policy is unavailable")
        }
        do { try CollectionRequirement.validate(requirements) } catch {
            throw ServerError.internalServerError("Exact collection policy is unavailable")
        }
        return requirements
    }

    /// Resolves retained bounds without consulting the current draft, device clock or time-zone rules.
    func resolvedRequirements(
        studyID: UUID, revision: Int, acceptedAt: Date, scope: AcceptedCollectionScope?, adoptionEnd: Date?
    ) throws -> [ResolvedRequirement] {
        let requirements = try validatedRequirements(studyID: studyID, revision: revision)
        guard CollectionMeasurementWindow.valid(acceptedAt),
              scope.map({ $0.requirements.count == requirements.count }) ?? true else { throw Self.missingScope }
        return try requirements.map { requirement in
            let retained = scope?.requirements.filter { $0.profile == requirement.profile && $0.sourceKind == requirement.sourceKind }
            let window: ResolvedCollectionWindow
            if let retained {
                guard retained.count == 1, let value = retained.first else { throw Self.missingScope }
                window = value.window
            } else {
                guard requirement.measurementWindow == nil else { throw Self.missingScope }
                window = .init(start: nil, end: nil)
            }
            try Self.validate(window, for: requirement, acceptedAt: acceptedAt)
            let lower = window.start ?? acceptedAt
            let upper = [window.end, adoptionEnd].compactMap { $0 }.min()
            guard CollectionMeasurementWindow.valid(lower), window.end.map({ CollectionMeasurementWindow.valid($0) && $0 > lower }) ?? true else {
                throw Self.missingScope
            }
            // A later revision can close a future explicit range before it starts: retain an empty interval.
            return .init(profile: requirement.profile, sourceKind: requirement.sourceKind, start: lower, end: upper.map { max(lower, $0) })
        }
    }

    // Call only for an IG-validated point Quantity after resolving active server-owned authority.
    // swiftlint:disable:next function_parameter_count
    func permits(
        studyID: UUID,
        revision: Int,
        profile: String,
        sourceKind: SourceKind,
        effectiveAt: Date,
        consentAcceptedAt: Date,
        scope: AcceptedCollectionScope? = nil,
        adoptionEnd: Date? = nil
    ) -> Bool {
        guard let requirements = try? resolvedRequirements(
            studyID: studyID, revision: revision, acceptedAt: consentAcceptedAt, scope: scope, adoptionEnd: adoptionEnd
        ) else { return false }
        return requirements.contains { $0.profile == profile && $0.sourceKind == sourceKind && $0.contains(effectiveAt) }
    }
}
