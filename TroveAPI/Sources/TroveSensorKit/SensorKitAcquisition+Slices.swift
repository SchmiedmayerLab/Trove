//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIClient


extension SensorKitAcquisition {
    struct RowAuthorization: Sendable {
        let consents: [CollectionObservationProfile: Set<UUID>]
    }

    struct SlicePreparation: Sendable {
        let inputs: [Input]
        let state: ParticipantCollectionState
        let slices: [SensorKitRecordingSlice]
    }
}


#if os(iOS)
import GroveFHIRContract
import GroveSensorKit
import GroveSensorKitFHIR


extension SensorKitAcquisition {
    func collectTabularSlices<Sample: SensorKitSampleProtocol>(
        _ batch: GroveSensorKit.SensorKit.AnchoredBatch<Sample.SafeRepresentation>,
        sensor: Sensor<Sample>,
        localID: UUID,
        queryID: UUID,
        facts: SensorKitBatchSnapshot
    ) async throws -> Page where Sample.SafeRepresentation: SensorKitTabularSample {
        guard let token = batch.info.replayToken, let entry = SensorKitCatalog.current.entry(for: sensor) else {
            throw AcquisitionError.invalidBatch
        }
        let (_, sourceID) = try await registration(for: localID)
        let state = try await journal.collectionState()
        guard let snapshot = try state.snapshot?.active(), snapshot.permitsSensorKitAcquisition(sourceTypeIdentifier: entry.sourceToken) else {
            throw ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized
        }
        let context = await TabularSliceContext(
            batch: batch, entry: entry, title: sensor.displayName, snapshot: snapshot, limits: journal.configuredLimits
        )
        let retained = try await journal.sensorKitBatchEvidence(
            sourceID: sourceID,
            sourceTypeIdentifier: entry.sourceToken,
            deviceProductType: batch.info.device.productType,
            coordinate: batch.info.acquisitionBatch.stableValue
        )
        let usesSlices = try retained.map { try SensorKitBatchReceipt(encoded: $0.firstReceipt).version == 2 } ?? true
        let covered = try await journal.sensorKitRecordingSlices(
            sourceID: sourceID,
            sourceTypeIdentifier: entry.sourceToken,
            deviceProductType: batch.info.device.productType,
            coordinate: batch.info.acquisitionBatch.stableValue
        )
        let original = try context.input(range: batch.samples.indices, sliceIdentity: false)
        let preparation = try context.prepare(covered: covered, usesSlices: usesSlices, original: original, state: state)
        return try await stage(
            Batch(
                coordinate: batch.info.acquisitionBatch.stableValue,
                sourceToken: entry.sourceToken,
                deviceProductType: batch.info.device.productType,
                inputs: [original],
                facts: facts,
                acknowledge: { try await batch.acknowledge() },
                replayToken: token.encoded(),
                nativeSampleCount: batch.samples.count,
                slicePreparation: preparation,
                usesRecordingSlices: usesSlices
            ),
            localID: localID,
            queryID: queryID
        )
    }
}
#endif
