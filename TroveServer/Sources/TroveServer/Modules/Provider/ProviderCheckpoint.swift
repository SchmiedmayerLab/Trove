//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SQLKit


struct ProviderCheckpoint: Sendable {
    enum Purpose: String, Sendable { case ordinary, reconciliation }
    enum Status: String, Sendable { case ready, fetching, staged, blocked, complete }

    static let maximumPages = 4096
    static let maximumFailures = 16

    let id: UUID
    let purpose: Purpose
    let queryAsOf: Date
    let window: Range<Date>
    let coverage: ProviderQueryCoverage
    let generation: Int64
    let status: Status
    let cursor: String?
    let leaseID: UUID?
    let leaseUntil: Date?
    let acquiredAt: Date?
    let acquisitionFacts: ProviderAcquisitionFacts?
    let pageSequence: Int64

    init(row: any SQLRow) throws {
        id = try row.decode(column: "id", as: UUID.self)
        guard let purpose = Purpose(rawValue: try row.decode(column: "purpose", as: String.self)) else { throw ProviderFailure.unavailable }
        self.purpose = purpose
        queryAsOf = try row.decode(column: "query_as_of", as: Date.self)
        let start = try row.decode(column: "window_start", as: Date.self)
        let end = try row.decode(column: "window_end", as: Date.self)
        generation = try row.decode(column: "generation", as: Int64.self)
        pageSequence = try row.decode(column: "page_sequence", as: Int64.self)
        guard start < end, generation > 0, pageSequence > 0,
              let status = Status(rawValue: try row.decode(column: "status", as: String.self)) else { throw ProviderFailure.unavailable }
        window = start..<end
        coverage = try ProviderSQL.decode(row.decode(column: "query_coverage", as: String.self), maximumBytes: ProviderQueryCoverage.maximumBytes)
        try coverage.validate(window: window)
        guard try coverage.digest == row.decode(column: "coverage_digest", as: String.self) else { throw ProviderFailure.unavailable }
        self.status = status
        cursor = try row.decode(column: "cursor", as: String?.self)
        leaseID = try row.decode(column: "lease_id", as: UUID?.self)
        leaseUntil = try row.decode(column: "lease_until", as: Date?.self)
        acquiredAt = try row.decode(column: "acquired_at", as: Date?.self)
        acquisitionFacts = try row.decode(column: "acquisition_facts", as: String?.self).map { try ProviderSQL.decode($0, maximumBytes: 16_384) }
    }
}
