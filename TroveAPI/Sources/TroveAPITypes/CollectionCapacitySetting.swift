//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

/// Deployment keys shared by producers and receivers. Values are positive decimal integers.
public enum CollectionCapacitySetting: String, CaseIterable, Sendable {
    case recordBytes = "COLLECTION_MAX_RECORD_BYTES"
    case bundleBytes = "COLLECTION_MAX_BUNDLE_BYTES"
    case envelopeBytes = "COLLECTION_MAX_ENVELOPE_BYTES"
    case batchRecords = "COLLECTION_MAX_BATCH_RECORDS"
    case exportBundleBytes = "STUDY_EXPORT_MAX_BUNDLE_BYTES"
    case exportPageBytes = "STUDY_EXPORT_MAX_PAGE_BYTES"
    case pendingBytes = "COLLECTION_MAX_PENDING_BYTES"
    case databaseBytes = "COLLECTION_MAX_DATABASE_BYTES"
    case recordingBytes = "COLLECTION_MAX_RECORDING_BYTES"
    case pendingRecordingBytes = "COLLECTION_MAX_PENDING_RECORDING_BYTES"
    case pendingEvents = "COLLECTION_MAX_PENDING_EVENTS"
    case queries = "COLLECTION_MAX_QUERIES"
    case recordingFiles = "COLLECTION_MAX_RECORDING_FILES"

    public enum Failure: Error { case invalidValue(CollectionCapacitySetting) }

    public func read(from values: [String: String], default fallback: Int) throws -> Int {
        guard let raw = values[rawValue] else {
            return fallback
        }
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(raw), value > 0 else {
            throw Failure.invalidValue(self)
        }
        return value
    }
}
