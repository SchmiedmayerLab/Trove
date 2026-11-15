//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import TroveAPITypes


/// One producer configuration supplies acquisition staging and transport packing budgets.
public struct EventDeliveryCapacityConfiguration: Sendable {
    public let admission: EventSubmissionLimits.Configuration
    public let journal: EventDeliveryJournal.Limits

    public init(settings: [String: String] = [:]) throws {
        admission = try .init(settings: settings)
        let defaults = EventDeliveryJournal.Limits()
        journal = try .init(
            maximumPayloadBytes: admission.recordBytes,
            maximumBytes: CollectionCapacitySetting.pendingBytes.read(from: settings, default: defaults.maximumBytes),
            maximumEvents: CollectionCapacitySetting.pendingEvents.read(from: settings, default: defaults.maximumEvents),
            maximumQueries: CollectionCapacitySetting.queries.read(from: settings, default: defaults.maximumQueries),
            maximumDatabaseBytes: CollectionCapacitySetting.databaseBytes.read(from: settings, default: defaults.maximumDatabaseBytes),
            maximumRecordingBytes: CollectionCapacitySetting.recordingBytes.read(from: settings, default: defaults.maximumRecordingBytes),
            maximumPendingRecordingBytes: CollectionCapacitySetting.pendingRecordingBytes.read(
                from: settings, default: defaults.maximumPendingRecordingBytes
            ),
            maximumRecordingFiles: CollectionCapacitySetting.recordingFiles.read(from: settings, default: defaults.maximumRecordingFiles)
        )
        try journal.validate()
    }
}
