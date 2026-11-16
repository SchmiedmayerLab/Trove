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
    private struct QueryContext {
        let localID: UUID
        let queryID: UUID
        let application: ApplicationDevice
        let host: HostDevice
    }

    struct PreparedSample {
        let prepared: SensorKitPreparedStructuredRecord
        let start: Date
        let end: Date?
    }

    /// Preserves native sleep-session identity under the registered source's governed namespace.
    @available(iOS 26, *)
    public func collectSleepSessions(
        _ batch: GroveSensorKit.SensorKit.AnchoredBatch<SRSleepSession.SafeRepresentation>,
        localID: UUID,
        queryID: UUID,
        application: ApplicationDevice,
        host: HostDevice
    ) async throws -> Page {
        try await checkSession()
        let setup = try await journal.sourceSetup(for: localID)
        guard let registration = setup.binding, !registration.isRevoked,
              registration.source.repositoryKind == .sensorkit else { throw AcquisitionError.invalidBatch }
        let namespace = try IdentifierSystem(registration.source.identifierRoot + "/NamingSystem/sensorkit-sleep-session")
        return try await collectStructured(
            batch, sensor: .sleepSessions, context: QueryContext(localID: localID, queryID: queryID, application: application, host: host)
        ) { sample in
            PreparedSample(
                prepared: try SensorKitPreparedStructuredRecord(sleepSession: sample, identifierSystem: namespace),
                start: sample.startDate,
                end: sample.startDate.addingTimeInterval(sample.duration)
            )
        }
    }

    /// Converts visits with their exact arrival/departure uncertainty windows and governed native location identifier.
    public func collectVisits(
        _ batch: GroveSensorKit.SensorKit.AnchoredBatch<SRVisit.SafeRepresentation>,
        localID: UUID,
        queryID: UUID,
        application: ApplicationDevice,
        host: HostDevice
    ) async throws -> Page {
        try await collectStructured(
            batch, sensor: .visits, context: QueryContext(localID: localID, queryID: queryID, application: application, host: host)
        ) { sample in
            PreparedSample(
                prepared: try SensorKitPreparedStructuredRecord(visit: sample),
                start: sample.arrivalDateInterval.start,
                end: sample.departureDateInterval.end
            )
        }
    }

    /// Converts every public messages-usage count for one acknowledged native batch.
    public func collectMessagesUsage(
        _ batch: GroveSensorKit.SensorKit.AnchoredBatch<SRMessagesUsageReport.SafeRepresentation>,
        localID: UUID,
        queryID: UUID,
        application: ApplicationDevice,
        host: HostDevice
    ) async throws -> Page {
        try await collectStructured(
            batch, sensor: .messagesUsageReport, context: QueryContext(localID: localID, queryID: queryID, application: application, host: host)
        ) { sample in
            PreparedSample(
                prepared: try SensorKitPreparedStructuredRecord(messagesUsage: sample),
                start: sample.timestamp,
                end: sample.timestamp.addingTimeInterval(sample.duration)
            )
        }
    }

    /// Converts call-duration and count facts for one acknowledged native batch.
    public func collectPhoneUsage(
        _ batch: GroveSensorKit.SensorKit.AnchoredBatch<SRPhoneUsageReport.SafeRepresentation>,
        localID: UUID,
        queryID: UUID,
        application: ApplicationDevice,
        host: HostDevice
    ) async throws -> Page {
        try await collectStructured(
            batch, sensor: .phoneUsageReport, context: QueryContext(localID: localID, queryID: queryID, application: application, host: host)
        ) { sample in
            PreparedSample(
                prepared: try SensorKitPreparedStructuredRecord(phoneUsage: sample),
                start: sample.timestamp,
                end: sample.timestamp.addingTimeInterval(sample.duration)
            )
        }
    }

    private func collectStructured<Sample: Sendable>(
        _ batch: GroveSensorKit.SensorKit.AnchoredBatch<Sample>,
        sensor: SRSensor,
        context: QueryContext,
        prepare: @Sendable (Sample) throws -> PreparedSample
    ) async throws -> Page {
        try await checkSession()
        guard batch.samples.count <= 128, let replayToken = batch.info.replayToken, let token = SensorKitCatalog.sourceToken(for: sensor),
              let entry = SensorKitCatalog.current.entry(sourceToken: token),
              let canonical = entry.implementedOutput?.observation?.primaryProfile,
              let profile = CollectionObservationProfile(rawValue: canonical) else { throw AcquisitionError.invalidBatch }
        let facts = try SensorKitBatchSnapshot(
            application: context.application,
            host: context.host,
            recordingDevice: RecordingDevice(batch.info.device),
            sourceDevices: batch.info.sourceDevices.map(RecordingDevice.init),
            sourceDevicesSuppliedEverySample: batch.info.sourceDevicesSuppliedEverySample,
            sourceTimeZone: .current,
            conversionInstant: .now
        )
        let inputs = try batch.samples.enumerated().map { ordinal, sample in
            let sourceID = SensorKitSourceRecordID.derived(
                acquisitionBatch: batch.info.acquisitionBatch,
                sourceToken: token,
                deviceProductType: batch.info.device.productType,
                recordOrdinal: UInt64(ordinal)
            )
            let prepared = try prepare(sample)
            guard prepared.prepared.nativePayload == nil else { throw AcquisitionError.invalidBatch }
            return Input(
                sourceID: sourceID,
                sourceToken: token,
                profile: profile,
                record: try prepared.prepared.sensorKitRecord(sourceRecordID: sourceID),
                digest: Data(SHA256.hash(data: prepared.prepared.retryEvidence)),
                start: prepared.start,
                end: prepared.end
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
            localID: context.localID,
            queryID: context.queryID
        )
    }
}

#endif
