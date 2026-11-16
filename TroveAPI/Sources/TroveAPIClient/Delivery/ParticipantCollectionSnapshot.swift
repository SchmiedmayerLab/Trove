//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPITypes


/// A validated observation of accepted collection authority. Observation time is not an expiry.
/// Retained authority must honor local withdrawal; the receiver independently authorizes every upload.
public struct ParticipantCollectionSnapshot: Sendable {
    public enum CollectionError: Error, Equatable {
        case invalidPlan
        case unsupportedRequirement
        case collectionNotAuthorized
    }

    let plans: [Components.Schemas.ParticipantCollectionPlan]

    /// An active requirement is needed to start another query, even if historical windows remain.
    public var permitsHeartRateAcquisition: Bool {
        permitsAcquisition(of: .heartRate)
    }

    public var acquisitionProfiles: [CollectionObservationProfile] {
        acquisitionStreams.filter { $0 != .workoutRoute }.map(\.profile)
    }

    public var acquisitionStreams: [HealthKitQueryDefinition.Stream] {
        HealthKitQueryDefinition.Stream.allCases.filter { permitsAcquisition(stream: $0) }
    }

    /// Previously accepted streams for enrollments still present in this snapshot.
    /// These allow deletion processing on existing cursors, never collection of new samples.
    public var retainedStreams: [HealthKitQueryDefinition.Stream] {
        HealthKitQueryDefinition.Stream.allCases.filter { permitsRetractions(stream: $0) }
    }

    public var permitsSleepAcquisition: Bool { permitsAcquisition(of: .sleepStage) }

    public var sleepQueryStart: Date? { queryStart(for: .sleepStage) }

    /// Earliest eligible measurement time for explicit creation of a new stream.
    /// Keep the resulting query fixed; later consent changes never reset an existing anchor.
    public var heartRateQueryStart: Date? { queryStart(for: .heartRate) }

    /// The next authority change during a local query. The journal rechecks it before advancing a cursor.
    var acquisitionDeadline: Date? { plans.compactMap(\.endsAt).min() }

    /// Input must contain exactly one response for each requested enrollment.
    public init(plans: [Components.Schemas.ParticipantCollectionPlan], enrollmentIDs: [UUID]) throws {
        guard enrollmentIDs.count <= 128, Set(enrollmentIDs).count == enrollmentIDs.count,
              plans.count == enrollmentIDs.count else { throw CollectionError.invalidPlan }
        var remaining = Set(enrollmentIDs)
        var consentIDs: Set<UUID> = []
        for plan in plans {
            guard let id = UUID(uuidString: plan.enrollmentId), remaining.remove(id) != nil else { throw CollectionError.invalidPlan }
            try Self.validate(plan, consentIDs: &consentIDs)
        }
        self.plans = plans.sorted { $0.enrollmentId < $1.enrollmentId }
    }

    /// Uses exact half-open measurement windows. A point may be attributable to several studies.
    public func consentIDs(forHeartRateAt instant: Date) throws -> [UUID] {
        try consentIDs(profile: .heartRate, start: instant, end: nil)
    }

    /// Select the complete sleep interval when it overlaps a window; do not clip or split its identity.
    public func consentIDs(forSleepStarting start: Date, ending end: Date) throws -> [UUID] {
        try consentIDs(profile: .sleepStage, start: start, end: end)
    }

    /// Select one accepted consent per study for a complete measurement of the requested profile.
    public func consentIDs(
        profile: CollectionObservationProfile,
        start: Date,
        end: Date?,
        requiresWorkoutRoute: Bool = false,
        sourceTypeIdentifier: String? = nil,
        timeBasis: CollectionTimeBasis = .measurementTime
    ) throws -> [UUID] {
        guard !requiresWorkoutRoute || profile == .workout, profile.permitsEffectiveTime(hasEnd: end != nil),
              Self.validDate(start), end.map({ Self.validDate($0) && $0 >= start }) ?? true else {
            throw CollectionError.invalidPlan
        }
        // Select the latest eligible consent once per enrollment, including intervals crossing revisions.
        return try plans.compactMap { plan in
            guard let window = plan.windows.reversed().first(where: { window in
                window.requirements.contains {
                    $0.sourceKind == .participantApp && $0.profile == profile.rawValue
                        && Self.sourceMatches($0, sourceTypeIdentifier: sourceTypeIdentifier, requiresWorkoutRoute: requiresWorkoutRoute)
                        && ($0.timeBasis ?? .measurementTime) == timeBasis
                        && (!requiresWorkoutRoute || $0.includeWorkoutRoutes == true)
                        && CollectionMeasurementSelection.includes(
                        sampleStart: start, sampleEnd: end, windowStart: $0.start, windowEnd: $0.end
                    )
                }
            }) else { return nil }
            guard let id = UUID(uuidString: window.consentId) else { throw CollectionError.invalidPlan }
            return id
        }
    }

    /// Evaluate the retained enrollment ends locally. Measurement windows alone never expire enrollment.
    public func active(at instant: Date = .now) throws -> Self {
        guard Self.validDate(instant) else { throw CollectionError.invalidPlan }
        let active = plans.filter { $0.endsAt.map { instant < $0 } ?? true }
        return try Self(plans: active, enrollmentIDs: active.compactMap { UUID(uuidString: $0.enrollmentId) })
    }

    /// Server observation time naturally changes on refresh; enrollment versions and policy must not.
    public func hasSameAuthority(as other: Self) -> Bool {
        guard plans.count == other.plans.count else {
            return false
        }
        return zip(plans, other.plans).allSatisfy { previous, current in
            previous.enrollmentId == current.enrollmentId && previous.studyId == current.studyId
                && previous.endsAt == current.endsAt && previous.stateVersion == current.stateVersion && previous.windows == current.windows
                && current.asOf >= previous.asOf
        }
    }
}


extension ParticipantCollectionSnapshot {
    private struct RequirementIdentity: Hashable {
        let profile: String
        let sourceKind: String
        let providerRegistrationID: UUID?
        let sourceTypeIdentifier: String?

        init(_ requirement: Components.Schemas.CollectionPlanRequirement) {
            profile = requirement.profile
            sourceKind = requirement.sourceKind.rawValue
            providerRegistrationID = requirement.providerRegistrationId.flatMap(UUID.init(uuidString:))
            sourceTypeIdentifier = requirement.sourceTypeIdentifier
        }
    }

    /// Grove profile for a point heart-rate measurement.
    public static let heartRateProfile = CollectionObservationProfile.heartRate.rawValue
    /// Grove profile for a complete sleep-stage interval.
    public static let sleepStageProfile = CollectionObservationProfile.sleepStage.rawValue

    private static func validate(_ plan: Components.Schemas.ParticipantCollectionPlan, consentIDs: inout Set<UUID>) throws {
        guard plan.stateVersion > 0, validDate(plan.asOf), plan.endsAt.map(Self.validDate) ?? true, plan.windows.count <= 1024,
              UUID(uuidString: plan.studyId) != nil, (1...64).contains(plan.title.count),
              plan.title.allSatisfy({ (1...4096).contains($0.value.utf8.count) && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw CollectionError.invalidPlan }
        var previous: Components.Schemas.ConsentCollectionWindow?
        var publications: Set<UUID> = []
        for window in plan.windows {
            guard let consentID = UUID(uuidString: window.consentId), consentIDs.insert(consentID).inserted,
                  let publicationID = UUID(uuidString: window.publicationId), publications.insert(publicationID).inserted,
                  window.revision > 0, validDate(window.start), window.start <= plan.asOf,
                  window.end.map({ validDate($0) && $0 >= window.start && ($0 <= plan.asOf || $0 == plan.endsAt) }) ?? true else {
                throw CollectionError.invalidPlan
            }
            if let previous {
                guard previous.end == window.start, previous.revision < window.revision else { throw CollectionError.invalidPlan }
            }
            guard window.requirements.count <= CollectionObservationProfile.maximumRequirements,
                  Set(window.requirements.map(RequirementIdentity.init)).count == window.requirements.count else { throw CollectionError.invalidPlan }
            guard window.requirements.allSatisfy({
                CollectionObservationProfile(rawValue: $0.profile) != nil && Self.validSource($0)
                    && CollectionTimeBasis.accepts($0.timeBasis, profile: $0.profile, sourceTypeIdentifier: $0.sourceTypeIdentifier)
                    && ($0.includeWorkoutRoutes != true
                        || ($0.profile == CollectionObservationProfile.workout.rawValue && $0.sourceKind == .participantApp))
            }) else {
                throw CollectionError.unsupportedRequirement
            }
            try validateRequirements(window)
            previous = window
        }
        guard previous == nil || previous?.end == plan.endsAt else { throw CollectionError.invalidPlan }
    }

    private static func validSource(_ requirement: Components.Schemas.CollectionPlanRequirement) -> Bool {
        switch requirement.sourceKind {
        case .participantApp:
            requirement.providerRegistrationId == nil
                && CollectionObservationProfile(rawValue: requirement.profile)?.permitsNativeSource(requirement.sourceTypeIdentifier) == true
        case .serverWorker:
            requirement.providerRegistrationId.flatMap(UUID.init(uuidString:)) != nil
                && requirement.sourceTypeIdentifier.map { !$0.isEmpty && $0.utf8.count <= 256 } == true
        }
    }

    private static func validateRequirements(_ window: Components.Schemas.ConsentCollectionWindow) throws {
        for requirement in window.requirements {
            guard validDate(requirement.start),
                  requirement.end.map({ validDate($0) && $0 >= requirement.start }) ?? true else { throw CollectionError.invalidPlan }
            if let end = window.end {
                guard let upper = requirement.end, upper <= end || upper == requirement.start else { throw CollectionError.invalidPlan }
            }
        }
    }

    private static func sourceMatches(
        _ requirement: Components.Schemas.CollectionPlanRequirement, sourceTypeIdentifier: String?, requiresWorkoutRoute: Bool = false
    ) -> Bool {
        CollectionObservationProfile(rawValue: requirement.profile)?.matchesSource(
            expected: requirement.sourceTypeIdentifier, actual: sourceTypeIdentifier, requiresWorkoutRoute: requiresWorkoutRoute
        ) == true
    }

    private static func validDate(_ date: Date) -> Bool {
        (-62_135_596_800...253_402_300_799).contains(date.timeIntervalSince1970)
    }
    /// Whether a current accepted window requests this measurement.
    public func permitsAcquisition(of profile: CollectionObservationProfile, sourceTypeIdentifier: String? = nil) -> Bool {
        plans.contains { plan in
            plan.windows.last?.requirements.contains {
                $0.sourceKind == .participantApp && $0.profile == profile.rawValue
                    && Self.sourceMatches($0, sourceTypeIdentifier: sourceTypeIdentifier ?? profile.nativeSourceTypeIdentifier)
            } == true
        }
    }

    /// Whether the current accepted requirements request this independently queried stream.
    public func permitsAcquisition(stream: HealthKitQueryDefinition.Stream) -> Bool {
        plans.contains { $0.windows.last?.requirements.contains(where: stream.includes) == true }
    }

    /// A previous accepted requirement can maintain existing records after that requirement is disabled.
    /// Call `active` first; locally stopped enrollments are already absent from the retained snapshot.
    public func permitsRetractions(stream: HealthKitQueryDefinition.Stream) -> Bool {
        plans.contains { plan in plan.windows.contains { $0.requirements.contains(where: stream.includes) } }
    }

    /// Earliest nonempty measurement window for a currently requested profile.
    public func queryStart(for profile: CollectionObservationProfile) -> Date? {
        guard let stream = try? HealthKitQueryDefinition.Stream(profile) else {
            return nil
        }
        return queryStart(forStream: stream)
    }

    /// Earliest authorized window for this exact native stream, independent of streams sharing its profile.
    public func queryStart(forStream stream: HealthKitQueryDefinition.Stream) -> Date? {
        guard permitsAcquisition(stream: stream) else {
            return nil
        }
        return plans
            .flatMap(\.windows)
            .flatMap(\.requirements)
            .filter { requirement in stream.includes(requirement) && (requirement.end.map { $0 > requirement.start } ?? true) }
            .map(\.start)
            .min()
    }
}
