//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import ModelsR4


/// Exact ordering evidence from validated Provenance, independent of receipt time.
/// Fraction digits remain text so database ordering never rounds them through Double.
struct RecordedInstant: Sendable, Equatable {
    let seconds: Int64
    let fraction: String
}


extension RecordedInstant {
    init(_ instant: Instant) throws {
        guard let original = instant.time.originalSecondsString, original.utf8.count <= 4096 else {
            throw FHIRValidationClient.invalid
        }
        let parts = original.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let whole = Int(parts[0]), (0..<60).contains(whole) else {
            throw FHIRValidationClient.invalid
        }
        var digits = parts.count == 2 ? String(parts[1]) : ""
        guard parts.count == 1 || !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw FHIRValidationClient.invalid
        }
        while digits.last == "0" { digits.removeLast() }
        var integral = instant
        integral.time.second = Decimal(whole)
        let timestamp = try integral.asNSDate().timeIntervalSince1970
        guard let seconds = Int64(exactly: timestamp) else { throw FHIRValidationClient.invalid }
        self.init(seconds: seconds, fraction: digits)
    }

    static func extract(from resources: [String: ResourceProxy]) throws -> Self {
        let instants = resources.values.compactMap { resource -> Instant? in
            guard case .provenance(let provenance) = resource else {
                return nil
            }
            return provenance.recorded.value
        }
        guard instants.count == 1, let instant = instants.first else { throw FHIRValidationClient.invalid }
        return try Self(instant)
    }
}
