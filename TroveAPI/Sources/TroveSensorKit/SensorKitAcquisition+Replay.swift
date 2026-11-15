//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

#if os(iOS)

import Foundation
import GroveSensorKit
import TroveAPIClient


extension SensorKitAcquisition {
    struct ReplayContext {
        let sourceID: UUID
        let sourceToken: String
        let profile: CollectionObservationProfile
        let state: ParticipantCollectionState
        let authority: String
    }

    /// Replay progress is separate from the live cursor and scoped to accepted authority, never to observation time.
    func replayHistory<Sample: SensorKitSampleProtocol>(
        context: ReplayContext,
        sensorKit: GroveSensorKit.SensorKit,
        sensor: Sensor<Sample>,
        ecgProcessingLimits: SensorKitECGProcessingLimits = .init(),
        collect: @Sendable (GroveSensorKit.SensorKit.AnchoredBatch<Sample.SafeRepresentation>, UUID) async throws -> Void
    ) async throws -> Bool {
        guard let snapshot = try context.state.snapshot?.active() else {
            throw ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized
        }
        var remaining = 8
        for device in try await journal.sensorKitEvidenceDevices(sourceID: context.sourceID, sourceTypeIdentifier: context.sourceToken) {
            let queryID = try await partitionQuery(
                sourceID: context.sourceID, sourceToken: context.sourceToken, deviceProductType: device, replayAuthority: context.authority
            )
            let checkpoint = try await journal.collectionCheckpoint(for: context.sourceID, state: context.state, queryID: queryID)
            let after = try await replayPosition(checkpoint, sourceToken: context.sourceToken, device: device)
            let rows = try await journal.sensorKitBatchEvidencePage(
                sourceID: context.sourceID, sourceTypeIdentifier: context.sourceToken, deviceProductType: device, after: after, limit: remaining
            )
            for row in rows {
                try await checkSession()
                _ = try await journal.collectionCheckpoint(for: context.sourceID, state: context.state, queryID: queryID)
                if try row.stagedAuthority == context.authority || !snapshot.maySelect(
                    profile: context.profile,
                    sourceTypeIdentifier: context.sourceToken,
                    effectiveStart: row.evidence.effectiveStart,
                    effectiveEnd: row.evidence.effectiveEnd
                ) {
                    var receipt = try SensorKitBatchReceipt(encoded: row.evidence.firstReceipt)
                    receipt.phase = .staged
                    let checkpoint = try await journal.collectionCheckpoint(for: context.sourceID, state: context.state, queryID: queryID)
                    _ = try await journal.stage(from: checkpoint, nextCursor: receipt.encoded(), payloads: [])
                } else {
                    let token = try GroveSensorKit.SensorKit.BatchReplayToken(encoded: row.evidence.replayToken)
                    guard token.deviceProductType == device, token.acquisitionBatch.stableValue == row.evidence.coordinate else {
                        throw AcquisitionError.retryMismatch
                    }
                    let batch = try await sensorKit.replay(token, from: sensor, ecgProcessingLimits: ecgProcessingLimits)
                    try await collect(batch, queryID)
                }
                remaining -= 1
                if remaining == 0 {
                    return false
                }
            }
        }
        return true
    }

    private func replayPosition(_ checkpoint: EventDeliveryJournal.Checkpoint, sourceToken: String, device: String) async throws -> Int64 {
        guard let cursor = checkpoint.cursor else {
            return 0
        }
        let receipt = try SensorKitBatchReceipt(encoded: cursor)
        let position = try await journal.sensorKitEvidencePosition(
            sourceID: checkpoint.sourceID,
            sourceTypeIdentifier: sourceToken,
            deviceProductType: device,
            coordinate: receipt.coordinate
        )
        // A prepared batch was not fully staged; resume it with the original receipt before moving on.
        return receipt.phase == .staged ? position : position - 1
    }
}

#endif
