//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import TroveAPITypes


/// Immutable queried fields and authority windows; completion never implies coverage of another field.
struct ProviderQueryCoverage: Codable, Equatable, Sendable {
    struct Selection: Codable, Equatable, Sendable {
        let profile: String
        let start: String
        let end: String

        var window: Range<Date> {
            get throws {
                let codec = TroveDateTranscoder()
                let lower = try codec.decode(start), upper = try codec.decode(end)
                guard lower < upper else { throw ProviderFailure.unavailable }
                return lower..<upper
            }
        }
    }

    static let maximumBytes = 1_048_576
    let selections: [Selection]

    var encoded: String { get throws { try ProviderSQL.encode(self, maximumBytes: Self.maximumBytes) } }
    var digest: String {
        get throws { try SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined() }
    }

    init(demands: [ProviderDemand], window: Range<Date>) throws {
        let codec = TroveDateTranscoder()
        var selections: [Selection] = []
        for profile in Set(demands.map(\.profile)).sorted() {
            for range in ProviderDemandStore.windows(demands.filter { $0.profile == profile }) {
                let lower = max(range.lowerBound, window.lowerBound), upper = min(range.upperBound, window.upperBound)
                if lower < upper {
                    selections.append(try .init(profile: profile, start: codec.encode(lower), end: codec.encode(upper)))
                }
            }
        }
        guard !selections.isEmpty, selections.count <= ProviderDemandStore.maximumDemands else { throw ProviderFailure.capacityExceeded }
        self.selections = selections
    }

    func validate(window: Range<Date>) throws {
        guard !selections.isEmpty, selections.count <= ProviderDemandStore.maximumDemands else { throw ProviderFailure.unavailable }
        for selected in selections {
            let range = try selected.window
            guard !selected.profile.isEmpty, selected.profile.utf8.count <= 2048,
                  window.lowerBound <= range.lowerBound, range.upperBound <= window.upperBound else { throw ProviderFailure.unavailable }
        }
    }

    func intersecting(_ demands: [ProviderDemand]) throws -> [ProviderDemand] {
        var result: [ProviderDemand] = []
        for demand in demands {
            for selection in selections where selection.profile == demand.profile {
                let window = try selection.window
                let lower = max(demand.start, window.lowerBound), upper = min(demand.end, window.upperBound)
                guard lower < upper else { continue }
                result.append(try ProviderDemand(
                    consentID: demand.consentID, profile: demand.profile, start: lower, end: upper, asOf: demand.asOf
                ))
                guard result.count <= ProviderDemandStore.maximumDemands else { throw ProviderFailure.capacityExceeded }
            }
        }
        return result
    }
}
