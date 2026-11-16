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
    static let supportedProfile = CollectionObservationProfile.heartRate.rawValue

    let profile: String
    let sourceKind: SourceKind
    let measurementWindow: CollectionMeasurementWindow?
    let includeWorkoutRoutes: Bool

    init(profile: String, sourceKind: SourceKind, measurementWindow: CollectionMeasurementWindow? = nil, includeWorkoutRoutes: Bool = false) {
        self.profile = profile
        self.sourceKind = sourceKind
        self.measurementWindow = measurementWindow
        self.includeWorkoutRoutes = includeWorkoutRoutes
    }

    static func validate(_ requirements: [Self]) throws {
        guard requirements.count <= CollectionObservationProfile.allCases.count,
              Set(requirements.map(\.profile)).count == requirements.count,
              requirements.allSatisfy({ CollectionObservationProfile(rawValue: $0.profile) != nil
                  && (!$0.includeWorkoutRoutes || $0.profile == CollectionObservationProfile.workout.rawValue) }) else {
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
        let includeWorkoutRoutes: Bool

        func contains(_ instant: Date, through sampleEnd: Date? = nil) -> Bool {
            CollectionMeasurementWindow.valid(instant) && (sampleEnd.map(CollectionMeasurementWindow.valid) ?? true)
                && CollectionMeasurementSelection.includes(sampleStart: instant, sampleEnd: sampleEnd, windowStart: start, windowEnd: end)
        }
    }

    private static var missingScope: ServerError { .internalServerError("Exact accepted collection scope is unavailable") }

    static let filename = "collection-policy.json"

    let enrollmentPeriod: EnrollmentPeriod
    let schemaVersion: Int
    let contractVersion: String
    let contractRevision: String
    let studyID: UUID
    let revision: Int
    let valueShape: String
    let collectionWindow: String
    let requirements: [CollectionRequirement]

    static func compile(
        studyID: UUID, revision: Int, requirements: [CollectionRequirement], enrollmentPeriod: EnrollmentPeriod = .ongoing
    ) throws -> Self {
        guard revision > 0 else { throw ServerError.badRequest("Collection policy revision must be positive") }
        try enrollmentPeriod.validate()
        try CollectionRequirement.validate(requirements)
        return Self(
            enrollmentPeriod: enrollmentPeriod,
            schemaVersion: 5,
            contractVersion: FHIRValidationClient.contractVersion,
            contractRevision: FHIRValidationClient.contractRevision,
            studyID: studyID,
            revision: revision,
            valueShape: "profiled-observation",
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
        guard schemaVersion == 5, contractVersion == FHIRValidationClient.contractVersion,
              contractRevision == FHIRValidationClient.contractRevision,
              self.studyID == studyID, self.revision == revision,
              revision > 0, valueShape == "profiled-observation", collectionWindow == "retained-measurement-window" else {
            throw ServerError.internalServerError("Exact collection policy is unavailable")
        }
        do {
            try enrollmentPeriod.validate()
            try CollectionRequirement.validate(requirements)
        } catch {
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
                guard retained.count == 1, let value = retained.first,
                      value.includeWorkoutRoutes == requirement.includeWorkoutRoutes else { throw Self.missingScope }
                window = value.window
            } else {
                guard requirement.measurementWindow == nil, !requirement.includeWorkoutRoutes else { throw Self.missingScope }
                window = .init(start: nil, end: nil)
            }
            try Self.validate(window, for: requirement, acceptedAt: acceptedAt)
            let lower = window.start ?? acceptedAt
            let upper = [window.end, adoptionEnd].compactMap { $0 }.min()
            guard CollectionMeasurementWindow.valid(lower), window.end.map({ CollectionMeasurementWindow.valid($0) && $0 > lower }) ?? true else {
                throw Self.missingScope
            }
            // A later revision can close a future explicit range before it starts: retain an empty interval.
            return .init(
                profile: requirement.profile,
                sourceKind: requirement.sourceKind,
                start: lower,
                end: upper.map { max(lower, $0) },
                includeWorkoutRoutes: requirement.includeWorkoutRoutes
            )
        }
    }

    // Call only for an IG-validated observation after resolving active server-owned authority.
    // swiftlint:disable:next function_parameter_count
    func permits(
        studyID: UUID,
        revision: Int,
        profile: String,
        sourceKind: SourceKind,
        effectiveAt: Date,
        consentAcceptedAt: Date,
        effectiveEnd: Date? = nil,
        scope: AcceptedCollectionScope? = nil,
        adoptionEnd: Date? = nil,
        requiresWorkoutRoute: Bool = false
    ) -> Bool {
        // The profile determines its temporal shape; an interval end cannot be dropped.
        guard let capability = CollectionObservationProfile(rawValue: profile),
              capability.isInterval == (effectiveEnd != nil) else {
            return false
        }
        guard let requirements = try? resolvedRequirements(
            studyID: studyID, revision: revision, acceptedAt: consentAcceptedAt, scope: scope, adoptionEnd: adoptionEnd
        ) else { return false }
        return requirements.contains {
            $0.profile == profile && $0.sourceKind == sourceKind && $0.contains(effectiveAt, through: effectiveEnd)
                && (!requiresWorkoutRoute || $0.includeWorkoutRoutes)
        }
    }
}
