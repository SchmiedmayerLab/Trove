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
    struct Identity: Hashable {
        let profile: String
        let sourceKind: SourceKind
        let providerRegistrationID: UUID?
        let sourceTypeIdentifier: String?
    }


    /// Receiver capability, not a duplicate measurement catalog or substitute for IG validation.
    static let supportedProfile = CollectionObservationProfile.heartRate.rawValue

    let profile: String
    let sourceKind: SourceKind
    let providerRegistrationID: UUID?
    let sourceTypeIdentifier: String?
    let timeBasis: CollectionTimeBasis?
    let measurementWindow: CollectionMeasurementWindow?
    let includeWorkoutRoutes: Bool

    var identity: Identity {
        .init(profile: profile, sourceKind: sourceKind, providerRegistrationID: providerRegistrationID, sourceTypeIdentifier: sourceTypeIdentifier)
    }

    init(
        profile: String,
        sourceKind: SourceKind,
        measurementWindow: CollectionMeasurementWindow? = nil,
        includeWorkoutRoutes: Bool = false,
        providerRegistrationID: UUID? = nil,
        sourceTypeIdentifier: String? = nil,
        timeBasis: CollectionTimeBasis? = nil
    ) {
        self.profile = profile
        self.sourceKind = sourceKind
        self.providerRegistrationID = providerRegistrationID
        self.sourceTypeIdentifier = sourceTypeIdentifier
        self.timeBasis = timeBasis
        self.measurementWindow = measurementWindow
        self.includeWorkoutRoutes = includeWorkoutRoutes
    }

    private static func validSource(_ requirement: Self) -> Bool {
        guard let profile = CollectionObservationProfile(rawValue: requirement.profile) else {
            return false
        }
        if requirement.sourceKind == .participantApp {
            return profile.permitsNativeSource(requirement.sourceTypeIdentifier)
        }
        guard let identifier = requirement.sourceTypeIdentifier else {
            return false
        }
        return !identifier.isEmpty && identifier.utf8.count <= 256
    }

    static func validate(_ requirements: [Self]) throws {
        guard requirements.count <= CollectionObservationProfile.maximumRequirements,
              Set(requirements.map(\.identity)).count == requirements.count,
              requirements.allSatisfy({ validSource($0)
                  && CollectionTimeBasis.accepts($0.timeBasis, profile: $0.profile, sourceTypeIdentifier: $0.sourceTypeIdentifier)
                  && ($0.sourceKind == .serverWorker) == ($0.providerRegistrationID != nil)
                  && ($0.sourceKind == .participantApp || !$0.includeWorkoutRoutes)
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
        let providerRegistrationID: UUID?
        let sourceTypeIdentifier: String?
        let timeBasis: CollectionTimeBasis?
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
    /// Whether study data released under this revision includes device unit identifiers; see ``StudyDeviceUnitDisclosure``.
    let receivesDeviceUnitIdentifiers: Bool

    static func compile(
        studyID: UUID,
        revision: Int,
        requirements: [CollectionRequirement],
        enrollmentPeriod: EnrollmentPeriod = .ongoing,
        receivesDeviceUnitIdentifiers: Bool = false
    ) throws -> Self {
        guard revision > 0 else { throw ServerError.badRequest("Collection policy revision must be positive") }
        try enrollmentPeriod.validate()
        try CollectionRequirement.validate(requirements)
        return Self(
            enrollmentPeriod: enrollmentPeriod,
            schemaVersion: 6,
            contractVersion: FHIRValidationClient.contractVersion,
            contractRevision: FHIRValidationClient.contractRevision,
            studyID: studyID,
            revision: revision,
            valueShape: "profiled-observation",
            collectionWindow: "retained-measurement-window",
            requirements: requirements,
            receivesDeviceUnitIdentifiers: receivesDeviceUnitIdentifiers
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
        guard schemaVersion == 6, contractVersion == FHIRValidationClient.contractVersion,
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

    /// The retained disclosure setting of an exact, valid policy; an unknown policy fails instead of releasing unit facts.
    func validatedDeviceUnitDisclosure(studyID: UUID, revision: Int) throws -> Bool {
        _ = try validatedRequirements(studyID: studyID, revision: revision)
        return receivesDeviceUnitIdentifiers
    }

    /// Resolves retained bounds without consulting the current draft, device clock or time-zone rules.
    func resolvedRequirements(
        studyID: UUID, revision: Int, acceptedAt: Date, scope: AcceptedCollectionScope?, adoptionEnd: Date?
    ) throws -> [ResolvedRequirement] {
        let requirements = try validatedRequirements(studyID: studyID, revision: revision)
        guard CollectionMeasurementWindow.valid(acceptedAt),
              scope.map({ $0.requirements.count == requirements.count }) ?? true else { throw Self.missingScope }
        return try requirements.map { requirement in
            let retained = scope?.requirements.filter {
                $0.profile == requirement.profile && $0.sourceKind == requirement.sourceKind
                    && $0.providerRegistrationID == requirement.providerRegistrationID && $0.sourceTypeIdentifier == requirement.sourceTypeIdentifier
                    && $0.timeBasis == requirement.timeBasis
            }
            let window: ResolvedCollectionWindow
            if let retained {
                guard retained.count == 1, let value = retained.first,
                      value.includeWorkoutRoutes == requirement.includeWorkoutRoutes else { throw Self.missingScope }
                window = value.window
            } else {
                guard requirement.measurementWindow == nil, !requirement.includeWorkoutRoutes, requirement.providerRegistrationID == nil,
                      requirement.sourceTypeIdentifier == nil, requirement.timeBasis == nil else {
                    throw Self.missingScope
                }
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
                providerRegistrationID: requirement.providerRegistrationID,
                sourceTypeIdentifier: requirement.sourceTypeIdentifier,
                timeBasis: requirement.timeBasis,
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
        preciseBounds: ClinicalMeasurementBounds? = nil,
        scope: AcceptedCollectionScope? = nil,
        adoptionEnd: Date? = nil,
        requiresWorkoutRoute: Bool = false,
        providerRegistrationID: UUID? = nil,
        sourceTypeIdentifier: String? = nil,
        timeBasis: CollectionTimeBasis = .measurementTime,
        rowExtent: RecordingRowExtent? = nil
    ) -> Bool {
        // The profile determines its temporal shape; an interval end cannot be dropped.
        guard let capability = CollectionObservationProfile(rawValue: profile),
              capability.permitsEffectiveTime(hasEnd: effectiveEnd != nil) else {
            return false
        }
        guard let requirements = try? resolvedRequirements(
            studyID: studyID, revision: revision, acceptedAt: consentAcceptedAt, scope: scope, adoptionEnd: adoptionEnd
        ) else {
            return false
        }
        return requirements.contains { requirement in
            requirement.profile == profile && requirement.sourceKind == sourceKind && requirement.providerRegistrationID == providerRegistrationID
                && (requirement.timeBasis ?? .measurementTime) == timeBasis
                && capability.matchesSource(
                    expected: requirement.sourceTypeIdentifier, actual: sourceTypeIdentifier, requiresWorkoutRoute: requiresWorkoutRoute
                )
                && ((try? (preciseBounds ?? ClinicalMeasurementBounds(start: effectiveAt, end: effectiveEnd))
                    .includes(windowStart: requirement.start, windowEnd: requirement.end)) == true)
                // A query-created batch has independent rows: the same window must select each of them.
                && (rowExtent.map { (try? $0.isSelected(windowStart: requirement.start, windowEnd: requirement.end)) == true } ?? true)
                && (!requiresWorkoutRoute || requirement.includeWorkoutRoutes)
        }
    }
}
