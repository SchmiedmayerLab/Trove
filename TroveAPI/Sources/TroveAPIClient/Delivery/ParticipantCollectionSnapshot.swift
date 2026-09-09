//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPITypes


/// A validated observation of collection authority, not an offline lease or an upload grant.
/// Refresh around acquisition; the receiver independently authorizes every submitted output.
public struct ParticipantCollectionSnapshot: Sendable {
    public enum CollectionError: Error, Equatable {
        case invalidPlan
        case unsupportedRequirement
        case collectionNotAuthorized
    }

    private let plans: [Components.Schemas.ParticipantCollectionPlan]

    /// An active requirement is needed to start another query, even if historical windows remain.
    public var permitsHeartRateAcquisition: Bool {
        plans.contains { $0.windows.last?.requirements.contains { $0.profile == Self.heartRateProfile } == true }
    }

    /// Earliest eligible measurement time for explicit creation of a new stream.
    /// Keep the resulting query fixed; later consent changes never reset an existing anchor.
    public var heartRateQueryStart: Date? {
        guard permitsHeartRateAcquisition else {
            return nil
        }
        return plans
            .flatMap(\.windows)
            .filter { window in
                window.requirements.contains { $0.profile == Self.heartRateProfile }
                    && (window.end.map { $0 > window.start } ?? true)
            }
            .map(\.start)
            .min()
    }

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
        guard Self.validDate(instant) else { throw CollectionError.invalidPlan }
        return try plans.flatMap { plan in
            try plan.windows.compactMap { window in
                guard instant >= window.start, window.end.map({ instant < $0 }) ?? true,
                      window.requirements.contains(where: { $0.profile == Self.heartRateProfile }) else { return nil }
                guard let id = UUID(uuidString: window.consentId) else { throw CollectionError.invalidPlan }
                return id
            }
        }
    }

    /// Server observation time naturally changes on refresh; enrollment versions and policy must not.
    public func hasSameAuthority(as other: Self) -> Bool {
        guard plans.count == other.plans.count else {
            return false
        }
        return zip(plans, other.plans).allSatisfy { previous, current in
            previous.enrollmentId == current.enrollmentId && previous.stateVersion == current.stateVersion && previous.windows == current.windows
                && current.asOf >= previous.asOf
        }
    }
}


extension ParticipantCollectionSnapshot {
    /// The initial receiver capability, not a second measurement catalog.
    public static let heartRateProfile = "https://grovealliance.org/fhir/mobile/StructureDefinition/grove-mobile-heart-rate"

    private static func validate(_ plan: Components.Schemas.ParticipantCollectionPlan, consentIDs: inout Set<UUID>) throws {
        guard plan.stateVersion > 0, validDate(plan.asOf), plan.windows.count <= 1024 else { throw CollectionError.invalidPlan }
        var previous: Components.Schemas.ConsentCollectionWindow?
        var publications: Set<UUID> = []
        for window in plan.windows {
            guard let consentID = UUID(uuidString: window.consentId), consentIDs.insert(consentID).inserted,
                  let publicationID = UUID(uuidString: window.publicationId), publications.insert(publicationID).inserted,
                  window.revision > 0, validDate(window.start), window.start <= plan.asOf,
                  window.end.map({ validDate($0) && $0 >= window.start && $0 <= plan.asOf }) ?? true else {
                throw CollectionError.invalidPlan
            }
            if let previous {
                guard previous.end == window.start, previous.revision < window.revision else { throw CollectionError.invalidPlan }
            }
            guard window.requirements.count <= 1 else { throw CollectionError.invalidPlan }
            guard window.requirements.allSatisfy({ $0.profile == heartRateProfile && $0.sourceKind == .participantApp }) else {
                throw CollectionError.unsupportedRequirement
            }
            previous = window
        }
        guard previous?.end == nil else { throw CollectionError.invalidPlan }
    }

    private static func validDate(_ date: Date) -> Bool {
        (0...253_402_300_799).contains(date.timeIntervalSince1970)
    }
}
