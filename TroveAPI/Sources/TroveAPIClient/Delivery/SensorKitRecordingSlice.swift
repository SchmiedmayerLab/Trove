//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Immutable row coverage within one retained native batch. Study policy is not part of its identity.
public struct SensorKitRecordingSlice: Sendable, Equatable {
    public let rows: Range<Int>
    public let sourceRecordID: UUID
    public let contentDigest: Data

    public init(rows: Range<Int>, sourceRecordID: UUID, contentDigest: Data) throws {
        guard rows.lowerBound >= 0, !rows.isEmpty, rows.upperBound <= Int(Int32.max), contentDigest.count == 32 else {
            throw DeliveryJournalError.invalidConfiguration
        }
        self.rows = rows
        self.sourceRecordID = sourceRecordID
        self.contentDigest = contentDigest
    }
}
