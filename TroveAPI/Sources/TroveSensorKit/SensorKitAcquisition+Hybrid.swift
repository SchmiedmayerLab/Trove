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
    private struct RecordingContext: Sendable {
        let localID: UUID
        let application: ApplicationDevice
        let host: HostDevice
    }

    struct RecordingBatchContext: Sendable {
        let localID: UUID
        let queryID: UUID
        let facts: SensorKitBatchSnapshot
    }

    /// Stages the complete ECG session and its clinical waveform before acknowledging the native batch.
    public func catchUpElectrocardiogram(
        localID: UUID,
        sensorKit: GroveSensorKit.SensorKit,
        application: ApplicationDevice,
        host: HostDevice,
        processingLimits: SensorKitECGProcessingLimits = .init()
    ) async throws -> Bool {
        try await catchUpRecordedSamples(
            Sensor.ecg,
            sensorKit: sensorKit,
            context: RecordingContext(localID: localID, application: application, host: host),
            ecgProcessingLimits: processingLimits
        ) { sample, entry, sourceID, maximumBytes in
            guard let first = sample.batches.first else { throw AcquisitionError.invalidBatch }
            return try Self.structuredFileInput(
                SensorKitPreparedStructuredFile(electrocardiogram: sample, maximumByteCount: maximumBytes),
                entry: entry,
                sourceID: sourceID,
                title: Sensor.ecg.displayName,
                period: Self.recordingPeriod(
                    start: sample.startDate.addingTimeInterval(first.offset), end: sample.startDate.addingTimeInterval(sample.duration)
                )
            )
        }
    }

    /// Keeps the source usage detail alongside its independently scoped clinical summary.
    public func catchUpDeviceUsage(
        localID: UUID, sensorKit: GroveSensorKit.SensorKit, application: ApplicationDevice, host: HostDevice
    ) async throws -> Bool {
        try await catchUpRecordedSamples(
            Sensor.deviceUsage, sensorKit: sensorKit, context: RecordingContext(localID: localID, application: application, host: host)
        ) { sample, entry, sourceID, maximumBytes in
            try Self.structuredFileInput(
                SensorKitPreparedStructuredFile(deviceUsage: sample, maximumByteCount: maximumBytes),
                entry: entry,
                sourceID: sourceID,
                title: Sensor.deviceUsage.displayName,
                period: Self.recordingPeriod(start: sample.timestamp, end: sample.timestamp.addingTimeInterval(sample.duration))
            )
        }
    }

    /// Retains one complete temperature session, its algorithm version and exact source rows.
    public func catchUpWristTemperature(
        localID: UUID, sensorKit: GroveSensorKit.SensorKit, application: ApplicationDevice, host: HostDevice
    ) async throws -> Bool {
        try await catchUpRecordedSamples(
            Sensor.wristTemperature, sensorKit: sensorKit, context: RecordingContext(localID: localID, application: application, host: host)
        ) { sample, entry, sourceID, maximumBytes in
            try Self.tabularInput(
                SensorKitTabularRecording.File(wristTemperature: sample.sample, maximumByteCount: maximumBytes),
                entry: entry,
                sourceID: sourceID,
                title: Sensor.wristTemperature.displayName
            )
        }
    }

    /// Retains every native photoplethysmogram sample as its registered recording and coverage summary.
    public func catchUpPhotoplethysmogram(
        localID: UUID, sensorKit: GroveSensorKit.SensorKit, application: ApplicationDevice, host: HostDevice
    ) async throws -> Bool {
        try await catchUpRecordedSamples(
            Sensor.ppg, sensorKit: sensorKit, context: RecordingContext(localID: localID, application: application, host: host)
        ) { sample, entry, sourceID, maximumBytes in
            try await Self.photoplethysmogramInput(
                SensorKitPPGRecording(samples: [sample]).prepared(),
                entry: entry,
                sourceID: sourceID,
                title: Sensor.ppg.displayName,
                maximumByteCount: maximumBytes
            )
        }
    }

    private func catchUpRecordedSamples<Sample: SensorKitSampleProtocol>(
        _ sensor: Sensor<Sample>,
        sensorKit: GroveSensorKit.SensorKit,
        context: RecordingContext,
        ecgProcessingLimits: SensorKitECGProcessingLimits? = nil,
        prepare: @escaping @Sendable (Sample.SafeRepresentation, SensorKitCatalogEntry, SensorKitSourceRecordID, Int) async throws -> Input
    ) async throws -> Bool {
        try await catchUp(
            localID: context.localID, sensorKit: sensorKit, sensor: sensor, ecgProcessingLimits: ecgProcessingLimits
        ) { batch, queryID in
            let facts = try SensorKitBatchSnapshot(
                application: context.application,
                host: context.host,
                recordingDevice: RecordingDevice(batch.info.device),
                sourceDevices: batch.info.sourceDevices.map(RecordingDevice.init),
                sourceDevicesSuppliedEverySample: batch.info.sourceDevicesSuppliedEverySample,
                sourceTimeZone: .current,
                conversionInstant: .now
            )
            _ = try await self.collectRecordedSamples(
                batch, for: sensor, context: RecordingBatchContext(localID: context.localID, queryID: queryID, facts: facts), prepare: prepare
            )
        }
    }
}


extension SensorKitAcquisition {
    func collectRecordedSamples<Sample: SensorKitSampleProtocol>(
        _ batch: GroveSensorKit.SensorKit.AnchoredBatch<Sample.SafeRepresentation>,
        for sensor: Sensor<Sample>,
        context: RecordingBatchContext,
        prepare: @Sendable (Sample.SafeRepresentation, SensorKitCatalogEntry, SensorKitSourceRecordID, Int) async throws -> Input
    ) async throws -> Page {
        try await checkSession()
        guard batch.samples.count <= 128, let replayToken = batch.info.replayToken,
              let entry = SensorKitCatalog.current.entry(for: sensor) else { throw AcquisitionError.invalidBatch }
        let limits = await journal.configuredLimits
        let maximumBytes = limits.maximumRecordingBytes
        // Original files share the configured pending-file budget. Compression can retain at most
        // another copy of those original bytes; durable queue storage has its own atomic capacity check.
        var remainingBytes = limits.maximumPendingRecordingBytes
        var inputs: [Input] = []
        for (ordinal, sample) in batch.samples.enumerated() {
            try Task.checkCancellation()
            let sourceID = SensorKitSourceRecordID.derived(
                acquisitionBatch: batch.info.acquisitionBatch,
                sourceToken: entry.sourceToken,
                deviceProductType: batch.info.device.productType,
                recordOrdinal: UInt64(ordinal)
            )
            guard remainingBytes > 0 else { throw EventDeliveryJournal.JournalError.capacityExceeded }
            let input: Input
            do {
                input = try await prepare(sample, entry, sourceID, min(maximumBytes, remainingBytes))
            } catch RecordingFile.FileError.byteLimitExceeded {
                throw EventDeliveryJournal.JournalError.capacityExceeded
            } catch RecordingCSVFileWriter.FileWriterError.payloadLimitExceeded {
                throw EventDeliveryJournal.JournalError.capacityExceeded
            }
            for recording in input.recordings {
                guard recording.file.byteCount <= remainingBytes else { throw EventDeliveryJournal.JournalError.capacityExceeded }
                remainingBytes -= recording.file.byteCount
            }
            inputs.append(input)
        }
        return try await stage(
            Batch(
                coordinate: batch.info.acquisitionBatch.stableValue,
                sourceToken: entry.sourceToken,
                deviceProductType: batch.info.device.productType,
                inputs: inputs,
                facts: context.facts,
                acknowledge: { try await batch.acknowledge() },
                replayToken: try replayToken.encoded(),
                nativeSampleCount: batch.samples.count
            ),
            localID: context.localID,
            queryID: context.queryID
        )
    }
}


extension SensorKitAcquisition {
    private static func recordingPeriod(start: Date, end: Date) throws -> DateInterval {
        guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, end >= start else {
            throw AcquisitionError.invalidBatch
        }
        return DateInterval(start: start, end: end)
    }

    static func structuredFileInput(
        _ recording: SensorKitPreparedStructuredFile,
        entry: SensorKitCatalogEntry,
        sourceID: SensorKitSourceRecordID,
        title: String,
        period: DateInterval
    ) throws -> Input {
        let profiles = try requiredProfiles(for: entry)
        guard let primary = profiles.first else { throw AcquisitionError.invalidBatch }
        let path = "recordings/\(sourceID.uuid.uuidString.lowercased()).json"
        var digest = SHA256()
        try recording.readRetryEvidenceChunks { digest.update(data: $0) }
        return Input(
            sourceID: sourceID,
            sourceToken: entry.sourceToken,
            profile: primary,
            record: try recording.sensorKitRecord(
                sourceRecordID: sourceID, title: title, sidecarPath: path, admission: .callerAuthorizedOpaquePayload
            ),
            digest: Data(digest.finalize()),
            start: period.start,
            end: period.end,
            companionProfiles: Array(profiles.dropFirst()),
            recordings: [.init(file: recording.file, format: .nativeRecording, relativePath: path)]
        )
    }
}

#endif
