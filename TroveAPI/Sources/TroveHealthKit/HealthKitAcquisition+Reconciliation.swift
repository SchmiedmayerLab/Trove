//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

#if canImport(HealthKit)

import Foundation
import GroveFHIRContract
import GroveHealthKit
import HealthKit
import TroveAPIClient


extension HealthKitAcquisition {
    /// Performs at most eight pages of a current online instruction, preserving its original bounded query.
    /// An expired lease requires online renewal; a completed query is never restarted by this method.
    /// HealthKit answers a type that was never requested with no samples, which must not complete a sweep.
    public func reconcile(localID: UUID, instructionID: UUID, healthKit: GroveHealthKit.HealthKit) async throws -> Progress {
        try await checkSession()
        let setup = try await journal.sourceSetup(for: localID)
        guard let binding = setup.binding, !binding.isRevoked, let sourceID = UUID(uuidString: binding.source.id) else {
            throw EventDeliveryJournal.JournalError.sourceRevoked
        }
        let existing = try await journal.checkpoint(for: sourceID, queryID: instructionID)
        if existing.queryExhausted, existing.lastServedSequence > 0 {
            return .caughtUp
        }
        let type = try Self.sampleType(for: HealthKitQueryDefinition(bytes: existing.queryDefinition).stream)
        guard await healthKit.didAskForAuthorization(toRead: [type as HKObjectType]) else {
            return .needsAnotherPass
        }
        let state = try await journal.collectionState()
        let maximumRecordingBytes = await journal.recordingByteLimit
        return try await Self.catchUp {
            try await collect(
                localID: localID,
                application: ApplicationDevice(bundle: .main),
                host: .current(),
                selection: .init(queryID: instructionID, state: state, kind: .reconciliation)
            ) { definition, previous in
                try await Self.query(healthKit, definition: definition, anchor: previous, maximumRecordingBytes: maximumRecordingBytes)
            }
        }
    }

    func collectionAuthority(
        for sourceID: UUID, state: ParticipantCollectionState, selection: Selection?
    ) async throws -> (ParticipantCollectionSnapshot, EventDeliveryJournal.Checkpoint) {
        if let selection, selection.kind == .reconciliation {
            let verified = try await journal.nativeReconciliationSelection(id: selection.queryID, sourceID: sourceID, state: state)
            return (verified.snapshot, verified.checkpoint)
        }
        guard let active = try state.snapshot?.active(), !active.retainedStreams.isEmpty else {
            throw ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized
        }
        let checkpoint = try await journal.collectionCheckpoint(for: sourceID, state: state, queryID: selection?.queryID)
        return (active, checkpoint)
    }
}

#endif
