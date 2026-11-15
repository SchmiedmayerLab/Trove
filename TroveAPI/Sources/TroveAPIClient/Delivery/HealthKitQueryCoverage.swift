//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPITypes


/// Coverage is independent for each anchored stream, including workout routes. Query predicates alone cannot establish
/// coverage: an old cursor may have advanced past records that were not yet authorized.
struct HealthKitQueryCoverage {
    let stream: HealthKitQueryDefinition.Stream
    let consentIDs: Set<UUID>
    let ranges: [Range<Date>]
    let previousRanges: [Range<Date>]

    init(stream: HealthKitQueryDefinition.Stream, snapshot: ParticipantCollectionSnapshot, reconciled: Set<UUID>) {
        self.stream = stream
        let windows = snapshot.plans.flatMap(\.windows)
        consentIDs = Set(windows.compactMap { UUID(uuidString: $0.consentId) })
        ranges = Self.union(windows.flatMap(\.requirements).compactMap { Self.range($0, stream: stream) })
        let previous = windows.filter {
            UUID(uuidString: $0.consentId).map(reconciled.contains) == true
        }
        previousRanges = Self.union(previous.flatMap(\.requirements).compactMap { Self.range($0, stream: stream) })
    }

    func includes(_ definition: HealthKitQueryDefinition) -> Bool {
        definition.stream == stream && ranges.contains {
            $0.lowerBound < (definition.end ?? Date(timeIntervalSince1970: .infinity)) && $0.upperBound > definition.start
        }
    }

    func missing(before cutoff: Date, queries: [HealthKitQueryDefinition]) -> [Range<Date>] {
        let desired = ranges.compactMap { Self.intersection($0, Date(timeIntervalSince1970: -.infinity)..<cutoff) }
        let predicates = Self.union(queries.compactMap { query -> Range<Date>? in
            guard query.stream == stream else {
                return nil
            }
            let upper = min(query.end ?? cutoff, cutoff)
            return query.start < upper ? query.start..<upper : nil
        })
        let covered = Self.union(previousRanges.flatMap { authorized in
            predicates.compactMap { Self.intersection(authorized, $0) }
        })
        return Self.subtract(covered, from: desired)
    }
}


extension HealthKitQueryCoverage {
    private static func range(_ requirement: Components.Schemas.CollectionPlanRequirement, stream: HealthKitQueryDefinition.Stream) -> Range<Date>? {
        let upper = requirement.end ?? Date(timeIntervalSince1970: .infinity)
        guard stream.includes(requirement), requirement.start < upper else {
            return nil
        }
        return requirement.start..<upper
    }

    private static func union(_ ranges: [Range<Date>]) -> [Range<Date>] {
        var result: [Range<Date>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where !range.isEmpty {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    private static func intersection(_ first: Range<Date>, _ second: Range<Date>) -> Range<Date>? {
        let lower = max(first.lowerBound, second.lowerBound), upper = min(first.upperBound, second.upperBound)
        return lower < upper ? lower..<upper : nil
    }

    private static func subtract(_ covered: [Range<Date>], from desired: [Range<Date>]) -> [Range<Date>] {
        var result: [Range<Date>] = []
        for range in desired {
            var next = range.lowerBound
            for existing in covered where existing.upperBound > next && existing.lowerBound < range.upperBound {
                if existing.lowerBound > next { result.append(next..<min(existing.lowerBound, range.upperBound)) }
                next = max(next, existing.upperBound)
                if next >= range.upperBound { break }
            }
            if next < range.upperBound { result.append(next..<range.upperBound) }
        }
        return result
    }
}
