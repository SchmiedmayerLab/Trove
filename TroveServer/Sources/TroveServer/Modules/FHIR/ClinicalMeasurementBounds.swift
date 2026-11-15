//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import ModelsR4
import SQLKit
import TroveAPITypes


/// Exact clinical time is retained separately from database/display Date projections.
/// Authority dates use the API's canonical microseconds; source fractions are never rounded.
struct ClinicalMeasurementBounds: Sendable, Equatable {
    let start: RecordedInstant
    let end: RecordedInstant?

    var startDate: Date { start.date }
    var endDate: Date? { end?.date }

    init(start: RecordedInstant, end: RecordedInstant? = nil) throws {
        guard end.map({ $0 >= start }) ?? true else { throw FHIRValidationClient.invalid }
        self.start = start
        self.end = end
    }

    init(sourceStart: String, sourceEnd: String? = nil) throws {
        try self.init(start: RecordedInstant(Instant(sourceStart)), end: sourceEnd.map { try RecordedInstant(Instant($0)) })
    }

    init(start: Date, end: Date? = nil) throws {
        try self.init(start: RecordedInstant(authorityDate: start), end: end.map { try RecordedInstant(authorityDate: $0) })
    }

    init(row: any SQLRow) throws {
        let lower = try RecordedInstant(
            seconds: row.decode(column: "effective_seconds", as: Int64.self),
            fraction: row.decode(column: "effective_fraction", as: String.self)
        )
        let seconds = try row.decode(column: "effective_end_seconds", as: Int64?.self)
        let fraction = try row.decode(column: "effective_end_fraction", as: String?.self)
        guard (seconds == nil) == (fraction == nil) else { throw ServerError.unexpectedError }
        try self.init(start: lower, end: seconds.flatMap { second in fraction.map { RecordedInstant(seconds: second, fraction: $0) } })
    }

    /// Half-open point selection and whole overlapping sessions share one exact comparator.
    func includes(windowStart: Date, windowEnd: Date?, asOf: Date? = nil) throws -> Bool {
        let lower = try RecordedInstant(authorityDate: windowStart)
        let upper = try windowEnd.map { try RecordedInstant(authorityDate: $0) }
        guard upper.map({ $0 > lower }) ?? true else {
            return false
        }
        if let asOf {
            let accepted = try RecordedInstant(authorityDate: asOf)
            guard start <= accepted, end.map({ $0 <= accepted }) ?? true else {
                return false
            }
        }
        guard let end, end > start else {
            return start >= lower && (upper.map { start < $0 } ?? true)
        }
        return end > lower && (upper.map { start < $0 } ?? true)
    }

    func ends(onOrBefore date: Date) throws -> Bool {
        let boundary = try RecordedInstant(authorityDate: date)
        return start <= boundary && (end.map { $0 <= boundary } ?? true)
    }
}


extension RecordedInstant: Comparable {
    /// Search/display only. Permission checks compare the exact integer and canonical fraction.
    /// The fraction is added at the reference epoch, where `Date` is most precise and databases round it.
    var date: Date {
        Date(timeIntervalSinceReferenceDate: Double(seconds) - Date.timeIntervalBetween1970AndReferenceDate + (Double("0." + fraction) ?? 0))
    }

    init(authorityDate date: Date) throws {
        guard CollectionMeasurementWindow.valid(date) else { throw FHIRValidationClient.invalid }
        try self.init(Instant(TroveDateTranscoder().encode(date)))
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.seconds == rhs.seconds ? lhs.fraction.utf8.lexicographicallyPrecedes(rhs.fraction.utf8) : lhs.seconds < rhs.seconds
    }
}
