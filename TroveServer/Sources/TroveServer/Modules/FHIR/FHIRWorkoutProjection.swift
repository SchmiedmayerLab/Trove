//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import ModelsR4
import TroveAPITypes


/// A workout is one source record: its session and every segment are selected together.
/// Complete FHIR validation precedes this receiver capability check.
enum FHIRWorkoutProjection {
    static let segmentProfile = Canonicals.root + "/mobile/StructureDefinition/grove-mobile-workout-segment"
    static let activitySystem = Canonicals.root + "/mobile/CodeSystem/grove-workout-activity"
    static let segmentSystem = Canonicals.root + "/mobile/CodeSystem/grove-workout-segment-type"

    static func validate(resources: [String: ResourceProxy]) throws {
        let observations = resources.compactMap { address, resource -> (String, Observation)? in
            if case .observation(let observation) = resource { (address, observation) } else { nil }
        }
        let sessions = observations.filter { $0.1.meta?.profile?.contains(Profile.groveMobileWorkout) == true }
        let segments = observations.filter { $0.1.meta?.profile?.contains(Profile.groveMobileWorkoutSegment) == true }
        guard !sessions.isEmpty || !segments.isEmpty else {
            return
        }
        guard sessions.count == 1, sessions.count + segments.count == observations.count,
              let (_, session) = sessions.first else { throw FHIRValidationClient.invalid }
        let interval = try bounds(session)
        let references = session.hasMember ?? []
        let members = references.compactMap { $0.reference?.value?.string }
        guard references.allSatisfy({ $0.identifier == nil && $0.extension?.isEmpty != false }),
              members.count == references.count, Set(members).count == members.count,
              Set(members) == Set(segments.map(\.0)) else { throw FHIRValidationClient.invalid }
        for (_, segment) in segments {
            let range = try bounds(segment)
            guard range.0 >= interval.0, range.1 <= interval.1,
                  segment.hasMember?.isEmpty != false else { throw FHIRValidationClient.invalid }
        }
        for (_, observation) in observations {
            for component in observation.component ?? [] {
                // Retain every statistic in immutable bytes, without accepting reference-valued components.
                guard case .quantity(let quantity)? = component.value, quantity.comparator == nil,
                      quantity.value?.value != nil, quantity.system?.value != nil, quantity.code?.value != nil else {
                    throw FHIRValidationClient.invalid
                }
            }
        }
    }

    private static func bounds(_ observation: Observation) throws -> (Date, Date) {
        guard case .period(let period)? = observation.effective,
              let start = period.start?.value, let end = period.end?.value,
              start.time != nil, start.timeZone != nil, end.time != nil, end.timeZone != nil else {
            throw FHIRValidationClient.invalid
        }
        let lower = try start.asNSDate(), upper = try end.asNSDate()
        guard CollectionMeasurementWindow.valid(lower), CollectionMeasurementWindow.valid(upper), lower <= upper else {
            throw FHIRValidationClient.invalid
        }
        return (lower, upper)
    }

    /// Facts already belong to one validated event. Use its parent interval for collection authority,
    /// while keeping segment intervals intact in storage and study results.
    static func collectionOutputs(_ outputs: [ClinicalGrantStore.Output]) throws -> [ClinicalGrantStore.Output] {
        let sessions = outputs.filter { $0.profile == CollectionObservationProfile.workout.rawValue }
        let segments = outputs.filter { $0.profile == segmentProfile }
        guard !sessions.isEmpty || !segments.isEmpty else {
            return outputs
        }
        guard sessions.count == 1, sessions.count + segments.count == outputs.count,
              let session = sessions.first, let end = session.effectiveEnd else { throw FHIRValidationClient.invalid }
        guard segments.allSatisfy({ $0.effectiveAt >= session.effectiveAt && $0.effectiveEnd.map { $0 <= end } == true }) else {
            throw FHIRValidationClient.invalid
        }
        return outputs.map {
            .init(fullURL: $0.fullURL, profile: session.profile, effectiveAt: session.effectiveAt, effectiveEnd: end)
        }
    }

    static func requireCompleteSelection(_ selected: Set<String>, outputs: [ClinicalGrantStore.Output]) throws {
        guard outputs.contains(where: { $0.profile == CollectionObservationProfile.workout.rawValue || $0.profile == segmentProfile }) else {
            return
        }
        guard selected == Set(outputs.map(\.fullURL)) else {
            throw ServerError.forbidden("A workout selection must include its complete session and segments")
        }
    }
}
