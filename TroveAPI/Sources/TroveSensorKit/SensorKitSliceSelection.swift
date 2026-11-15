//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIClient


/// Plans immutable ranges over ordered replay evidence, without a per-row persistence table.
enum SensorKitSliceSelection {
    /// The consents that may retain one row, for every output its producer graph requires.
    typealias Authority = [CollectionObservationProfile: Set<UUID>]

    /// Uncovered rows form maximal runs that share one exact authority, so a boundary between two study
    /// windows always starts a new slice. A retained slice keeps its rows and is offered again only to
    /// consents that authorize all of them. `authority` returns nil for a row nobody may retain.
    static func ranges(
        count: Int, retained: [SensorKitRecordingSlice], maximumSlices: Int, authority: (Int) throws -> Authority?
    ) throws -> [Range<Int>] {
        guard count >= 0, maximumSlices > 0 else { throw SensorKitAcquisition.AcquisitionError.invalidBatch }
        let covered = retained.map(\.rows).sorted { $0.lowerBound < $1.lowerBound }
        guard covered.allSatisfy({ !$0.isEmpty && $0.lowerBound >= 0 && $0.upperBound <= count }),
              zip(covered, covered.dropFirst()).allSatisfy({ $0.upperBound <= $1.lowerBound }) else {
            throw SensorKitAcquisition.AcquisitionError.retryMismatch
        }
        var result: [Range<Int>] = []
        var cursor = 0
        for range in covered {
            try appendUncovered(cursor..<range.lowerBound, to: &result, maximumSlices: maximumSlices, authority: authority)
            if try sharedAuthority(range, authority: authority) != nil { try append(range, to: &result, maximumSlices: maximumSlices) }
            cursor = range.upperBound
        }
        try appendUncovered(cursor..<count, to: &result, maximumSlices: maximumSlices, authority: authority)
        return result
    }

    /// One row's authority under the accepted plans; nil unless every required output has a consent.
    static func authority(
        for interval: Range<Date>,
        profiles: [CollectionObservationProfile],
        sourceTypeIdentifier: String,
        snapshot: ParticipantCollectionSnapshot
    ) throws -> Authority? {
        var result: Authority = [:]
        for profile in profiles {
            let consents = try snapshot.sensorKitRowConsentIDs(
                profile: profile,
                sourceTypeIdentifier: sourceTypeIdentifier,
                start: interval.lowerBound,
                end: interval.isEmpty ? nil : interval.upperBound
            )
            guard !consents.isEmpty else {
                return nil
            }
            result[profile] = Set(consents)
        }
        return result.isEmpty ? nil : result
    }

    /// The consents that authorize every row of a range; nil when a required output has none.
    static func sharedAuthority(_ range: Range<Int>, authority: (Int) throws -> Authority?) throws -> Authority? {
        var shared: Authority?
        for row in range {
            guard let current = try authority(row) else {
                return nil
            }
            guard let previous = shared else {
                shared = current
                continue
            }
            guard previous.keys == current.keys else {
                return nil
            }
            shared = previous.merging(current) { $0.intersection($1) }
        }
        guard let shared, !shared.isEmpty, shared.values.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        return shared
    }

    private static func appendUncovered(
        _ range: Range<Int>, to result: inout [Range<Int>], maximumSlices: Int, authority: (Int) throws -> Authority?
    ) throws {
        var run: (start: Int, authority: Authority)?
        for row in range {
            let current = try authority(row)
            if let open = run, open.authority != current {
                try append(open.start..<row, to: &result, maximumSlices: maximumSlices)
                run = nil
            }
            if run == nil, let current { run = (row, current) }
        }
        if let run { try append(run.start..<range.upperBound, to: &result, maximumSlices: maximumSlices) }
    }

    private static func append(_ range: Range<Int>, to result: inout [Range<Int>], maximumSlices: Int) throws {
        guard result.count < maximumSlices else { throw EventDeliveryJournal.JournalError.capacityExceeded }
        result.append(range)
    }
}
