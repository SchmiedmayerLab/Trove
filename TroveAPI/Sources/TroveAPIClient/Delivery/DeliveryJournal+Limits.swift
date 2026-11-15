//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

extension DeliveryJournal.Limits {
    func validate() throws {
        guard (1...512 * 1024 * 1024).contains(maximumBytes),
              (1...DeliveryJournalSchema.maximumPayloadBytes).contains(maximumPayloadBytes),
              (1...65_536).contains(maximumEvents), (1...65_536).contains(maximumQueries),
              (65_536...1024 * 1024 * 1024).contains(maximumDatabaseBytes),
              (1...Int(Int32.max)).contains(maximumRecordingBytes),
              (1...64 * 1024 * 1024 * 1024).contains(maximumPendingRecordingBytes),
              (1...65_536).contains(maximumRecordingFiles) else {
            throw DeliveryJournalError.invalidConfiguration
        }
    }
}


extension DeliveryJournal {
    /// Read-only acquisition preflight budgets; the staging transaction still enforces current durable capacity.
    public var configuredLimits: Limits { limits }
}
