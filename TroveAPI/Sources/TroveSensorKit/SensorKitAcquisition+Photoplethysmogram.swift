//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import GroveFHIRContract
import GroveSensorKitFHIR
import TroveAPIClient


extension SensorKitAcquisition {
    /// One native photoplethysmogram sample in Grove's registered binary format beside its coverage summary.
    /// The summary is derived from the staged bytes, so both outputs describe the same exact recording.
    static func photoplethysmogramInput(
        _ recording: SensorKitPreparedPPGRecording,
        entry: SensorKitCatalogEntry,
        sourceID: SensorKitSourceRecordID,
        title: String,
        maximumByteCount: Int
    ) async throws -> Input {
        let profiles = try requiredProfiles(for: entry)
        guard let primary = profiles.first else { throw AcquisitionError.invalidBatch }
        let bytes = recording.data
        let chunks = AsyncStream<Data>(bufferingPolicy: .bufferingOldest(1)) { continuation in
            continuation.yield(bytes)
            continuation.finish()
        }
        let file = try await RecordingFile.stage(chunks: chunks, maximumByteCount: Int64(maximumByteCount))
        let path = "recordings/\(sourceID.uuid.uuidString.lowercased()).bin"
        let record = try SensorKitPPGRecord(
            sourceRecordID: sourceID,
            nativeRecording: SensorKitNativeRecording(
                title: title, format: recording.format, payload: .file(path: path, contents: file), admission: .callerAuthorizedOpaquePayload
            )
        )
        return Input(
            sourceID: sourceID,
            sourceToken: entry.sourceToken,
            profile: primary,
            record: .ppg(record),
            digest: Data(SHA256.hash(data: recording.retryEvidence)),
            start: record.coverage.start,
            end: record.coverage.end,
            companionProfiles: Array(profiles.dropFirst()),
            recordings: [.init(file: file, format: recording.format, relativePath: path)]
        )
    }
}
