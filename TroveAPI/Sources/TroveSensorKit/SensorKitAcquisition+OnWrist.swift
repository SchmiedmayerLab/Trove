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
import SensorKit
import TroveAPIClient


extension SensorKitAcquisition {
    /// Consumes one lazy Grove batch. The caller resolves an immutable journal query for the
    /// sensor/device partition; a failure leaves Grove's native batch outstanding for retry.
    public func collectOnWrist(
        _ batch: GroveSensorKit.SensorKit.AnchoredBatch<SensorKitOnWristEventSample>,
        localID: UUID,
        queryID: UUID,
        application: ApplicationDevice,
        host: HostDevice,
        timeZone: TimeZone = .current,
        at instant: Date = .now
    ) async throws -> Page {
        try await checkSession()
        guard batch.samples.count <= 128, let replayToken = batch.info.replayToken,
              let token = SensorKitCatalog.sourceToken(for: .onWristState) else {
            throw AcquisitionError.invalidBatch
        }
        let facts = try SensorKitBatchSnapshot(
            application: application,
            host: host,
            recordingDevice: RecordingDevice(batch.info.device),
            sourceDevices: batch.info.sourceDevices.map(RecordingDevice.init),
            sourceDevicesSuppliedEverySample: batch.info.sourceDevicesSuppliedEverySample,
            sourceTimeZone: timeZone,
            conversionInstant: instant
        )
        let inputs = try batch.samples.enumerated().map { ordinal, sample in
            let sourceID = SensorKitSourceRecordID.derived(
                acquisitionBatch: batch.info.acquisitionBatch,
                sourceToken: token,
                deviceProductType: batch.info.device.productType,
                recordOrdinal: UInt64(ordinal)
            )
            let prepared = try SensorKitPreparedStructuredRecord(onWrist: sample)
            let record = try prepared.sensorKitRecord(sourceRecordID: sourceID)
            guard let start = sample.onWrist ? sample.onWristDate : sample.offWristDate,
                  start <= sample.timestamp else { throw AcquisitionError.invalidBatch }
            return Input(
                sourceID: sourceID,
                sourceToken: token,
                profile: .onWrist,
                record: record,
                digest: Data(SHA256.hash(data: prepared.retryEvidence)),
                start: start,
                end: start == sample.timestamp ? nil : sample.timestamp
            )
        }
        return try await stage(
            Batch(
                coordinate: batch.info.acquisitionBatch.stableValue,
                sourceToken: token,
                deviceProductType: batch.info.device.productType,
                inputs: inputs,
                facts: facts,
                acknowledge: { try await batch.acknowledge() },
                replayToken: try replayToken.encoded()
            ),
            localID: localID,
            queryID: queryID
        )
    }
}

#endif
