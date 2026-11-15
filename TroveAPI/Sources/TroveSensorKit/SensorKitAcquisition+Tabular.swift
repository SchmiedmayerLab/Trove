//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

#if os(iOS)

import Crypto
import Foundation
import GroveFHIRContract
import GroveSensorKit
import GroveSensorKitFHIR
import TroveAPIClient


extension SensorKitAcquisition {
    /// Uses Grove's registered row mapping and bounded file writer; raw bytes never accumulate in an upload Data buffer.
    public func catchUpTabular<Sample: SensorKitSampleProtocol>(
        _ sensor: Sensor<Sample>,
        localID: UUID,
        sensorKit: GroveSensorKit.SensorKit,
        application: ApplicationDevice,
        host: HostDevice
    ) async throws -> Bool where Sample.SafeRepresentation: SensorKitTabularSample {
        try await catchUp(localID: localID, sensorKit: sensorKit, sensor: sensor) { batch, queryID in
            let facts = try SensorKitBatchSnapshot(
                application: application,
                host: host,
                recordingDevice: RecordingDevice(batch.info.device),
                sourceDevices: batch.info.sourceDevices.map(RecordingDevice.init),
                sourceDevicesSuppliedEverySample: batch.info.sourceDevicesSuppliedEverySample,
                sourceTimeZone: .current,
                conversionInstant: .now
            )
            _ = try await self.collectTabular(batch, for: sensor, localID: localID, queryID: queryID, facts: facts)
        }
    }

    func collectTabular<Sample: SensorKitSampleProtocol>(
        _ batch: GroveSensorKit.SensorKit.AnchoredBatch<Sample.SafeRepresentation>,
        for sensor: Sensor<Sample>,
        localID: UUID,
        queryID: UUID,
        facts: SensorKitBatchSnapshot
    ) async throws -> Page where Sample.SafeRepresentation: SensorKitTabularSample {
        try await checkSession()
        guard batch.info.replayToken != nil, let entry = SensorKitCatalog.current.entry(for: sensor),
              entry.sourceToken == Sample.SafeRepresentation.groveSourceToken else { throw AcquisitionError.invalidBatch }
        return try await collectTabularSlices(batch, sensor: sensor, localID: localID, queryID: queryID, facts: facts)
    }
}


extension SensorKitAcquisition {
    static func tabularInput(
        _ recording: SensorKitTabularRecording.File, entry: SensorKitCatalogEntry, sourceID: SensorKitSourceRecordID, title: String
    ) throws -> Input {
        let profiles = try requiredProfiles(for: entry)
        guard let primary = profiles.first else { throw AcquisitionError.invalidBatch }
        let path = "recordings/\(sourceID.uuid.uuidString.lowercased()).csv"
        var digest = SHA256()
        try recording.readRetryEvidenceChunks { digest.update(data: $0) }
        let record = try recording.sensorKitRecord(
            sourceRecordID: sourceID, title: title, sidecarPath: path, admission: .callerAuthorizedOpaquePayload
        )
        return Input(
            sourceID: sourceID,
            sourceToken: entry.sourceToken,
            profile: primary,
            record: record,
            digest: Data(digest.finalize()),
            start: recording.effectivePeriod.start,
            end: recording.effectivePeriod.end,
            companionProfiles: Array(profiles.dropFirst()),
            recordings: [.init(file: recording.file, format: recording.format, relativePath: path)]
        )
    }
}

#endif
