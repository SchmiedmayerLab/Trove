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


/// Stages SensorKit batches in the existing account journal before acknowledging their native cursor.
/// Scheduling and SensorKit permission prompts remain with the application.
public actor SensorKitAcquisition {
    public enum AcquisitionError: Error, Equatable {
        case authenticationRequired
        case invalidBatch
        case retryMismatch
        case conversionRefused
        case alreadyCollecting
    }

    public struct Page: Sendable {
        public let eventIDs: [UUID]
        public let sampleCount: Int
        public let recoveredStagedBatch: Bool
    }

    struct Recording: Sendable {
        let file: RecordingFile
        let format: RegisteredRecordingFormat
        let relativePath: String
    }

    struct PreparedPage: Sendable {
        let payloads: [EventDeliveryJournal.Payload]
        let declarations: [[Components.Schemas.RecordingTransferDeclaration]]
    }

    struct Input: Sendable {
        let sourceID: SensorKitSourceRecordID
        let sourceToken: String
        let profile: CollectionObservationProfile
        let record: SensorKitRecord
        let digest: Data
        let start: Date
        let end: Date?
        var companionProfiles: [CollectionObservationProfile] = []
        var recordings: [Recording] = []
        var rowAuthorization: RowAuthorization?
    }

    struct Batch: Sendable {
        let coordinate: String
        let sourceToken: String
        let deviceProductType: String
        let inputs: [Input]
        let facts: SensorKitBatchSnapshot
        let acknowledge: @Sendable () async throws -> Void
        var replayToken: Data?
        var nativeSampleCount: Int?
        var slicePreparation: SlicePreparation?
        var usesRecordingSlices = false
    }

    let journal: EventDeliveryJournal
    let validateSession: @Sendable () async throws -> Void
    var fetching = false
    private var collecting = false

    /// The validation closure checks the captured account generation locally; it performs no live authorization request.
    public init(
        journal: EventDeliveryJournal,
        scope: EventDeliveryJournal.Scope,
        validateSession: @escaping @Sendable () async throws -> Void
    ) throws {
        guard journal.scope == scope else { throw EventDeliveryJournal.JournalError.wrongScope }
        self.journal = journal
        self.validateSession = validateSession
    }

    func stage(_ batch: Batch, localID: UUID, queryID: UUID) async throws -> Page {
        guard !collecting else { throw AcquisitionError.alreadyCollecting }
        collecting = true
        defer { collecting = false }
        try await checkSession()
        let (registration, sourceID) = try await registration(for: localID)
        let state = try await preparationState(batch)
        guard let snapshot = try state.snapshot?.active(), snapshot.permitsSensorKitAcquisition(sourceTypeIdentifier: batch.sourceToken) else {
            throw ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized
        }
        var checkpoint = try await journal.collectionCheckpoint(for: sourceID, state: state, queryID: queryID)
        let definition = try SensorKitQueryDefinition(encoded: checkpoint.queryDefinition)
        guard definition.sourceToken == batch.sourceToken, definition.deviceProductType == batch.deviceProductType else {
            throw AcquisitionError.invalidBatch
        }
        let first = try await firstReceipt(for: batch, sourceID: sourceID)
        var receipt = first.receipt
        var needsPreparation = true
        if let cursor = checkpoint.cursor {
            let previous = try SensorKitBatchReceipt(encoded: cursor)
            if previous.coordinate == receipt.coordinate {
                try previous.verify(receipt)
                receipt = previous
                needsPreparation = batch.replayToken != nil && !first.retained
                if previous.phase == .staged && !needsPreparation {
                    try await checkSession()
                    // Refresh the collection-bound checkpoint before acknowledging already durable bytes.
                    _ = try await journal.collectionCheckpoint(for: sourceID, state: state, queryID: queryID)
                    try await batch.acknowledge()
                    return Page(eventIDs: [], sampleCount: batch.nativeSampleCount ?? batch.inputs.count, recoveredStagedBatch: true)
                }
            } else if previous.phase == .prepared {
                throw AcquisitionError.retryMismatch
            }
        }
        if needsPreparation {
            receipt.phase = .prepared
            try await checkSession()
            try await prepare(batch, receipt: receipt, checkpoint: checkpoint)
            checkpoint = try await journal.collectionCheckpoint(for: sourceID, state: state, queryID: queryID)
        }
        let prepared = try await preparePayloads(batch, receipt: receipt, source: registration.source, sourceID: sourceID, snapshot: snapshot)
        receipt.phase = .staged
        try await checkSession()
        let eventIDs = try await stagePayloads(prepared, batch: batch, receipt: receipt, checkpoint: checkpoint, snapshot: snapshot)
        try await checkSession()
        // A withdrawal or account switch after staging must also prevent native acknowledgement.
        _ = try await journal.collectionCheckpoint(for: sourceID, state: state, queryID: queryID)
        try await batch.acknowledge()
        return Page(eventIDs: eventIDs, sampleCount: batch.nativeSampleCount ?? batch.inputs.count, recoveredStagedBatch: false)
    }

    private func preparePayloads(
        _ batch: Batch,
        receipt: SensorKitBatchReceipt,
        source: Components.Schemas.ParticipantSource,
        sourceID: UUID,
        snapshot: ParticipantCollectionSnapshot
    ) async throws -> PreparedPage {
        let facts = try SensorKitBatchSnapshot(encoded: receipt.facts, maximumByteCount: SensorKitBatchReceipt.maximumFactsBytes)
        let privacy = try await journal.identityScope(for: sourceID)
        let exporter = try Self.exporter(source: source, privacy: privacy, facts: facts)
        return try await Self.payloads(
            batch.slicePreparation?.inputs ?? batch.inputs,
            exporter: exporter,
            facts: facts,
            snapshot: snapshot,
            limits: journal.configuredLimits
        )
    }

    private func preparationState(_ batch: Batch) async throws -> ParticipantCollectionState {
        if let preparation = batch.slicePreparation {
            return preparation.state
        }
        return try await journal.collectionState()
    }

    private func stagePayloads(
        _ prepared: PreparedPage,
        batch: Batch,
        receipt: SensorKitBatchReceipt,
        checkpoint: EventDeliveryJournal.Checkpoint,
        snapshot: ParticipantCollectionSnapshot
    ) async throws -> [UUID] {
        guard batch.replayToken != nil else {
            return try await journal.stage(
                from: checkpoint, nextCursor: receipt.encoded(), payloads: prepared.payloads, recordingDeclarations: prepared.declarations
            )
        }
        guard let evidence = try await journal.sensorKitBatchEvidence(
            sourceID: checkpoint.sourceID,
            sourceTypeIdentifier: batch.sourceToken,
            deviceProductType: batch.deviceProductType,
            coordinate: batch.coordinate
        ) else { throw AcquisitionError.retryMismatch }
        return try await journal.stageSensorKitBatch(
            from: checkpoint,
            nextCursor: receipt.encoded(),
            payloads: prepared.payloads,
            evidence: evidence,
            authority: snapshot.authorityFingerprint(),
            recordingDeclarations: prepared.declarations,
            recordingSlices: batch.slicePreparation?.slices ?? []
        )
    }

    private func firstReceipt(for batch: Batch, sourceID: UUID) async throws -> (receipt: SensorKitBatchReceipt, retained: Bool) {
        let current = try SensorKitBatchReceipt(batch: batch)
        guard let retained = try await journal.sensorKitBatchEvidence(
            sourceID: sourceID,
            sourceTypeIdentifier: batch.sourceToken,
            deviceProductType: batch.deviceProductType,
            coordinate: batch.coordinate
        ) else { return (current, false) }
        let original = try SensorKitBatchReceipt(encoded: retained.firstReceipt)
        try original.verify(current)
        guard retained.replayToken == batch.replayToken else { throw AcquisitionError.retryMismatch }
        return (original, true)
    }

    private func prepare(_ batch: Batch, receipt: SensorKitBatchReceipt, checkpoint: EventDeliveryJournal.Checkpoint) async throws {
        if let token = batch.replayToken {
            let start = batch.inputs.map(\.start).min() ?? batch.facts.conversionInstant
            let end = batch.inputs.map { $0.end ?? $0.start }.max() ?? start
            let evidence = try SensorKitBatchEvidence(
                sourceTypeIdentifier: batch.sourceToken,
                deviceProductType: batch.deviceProductType,
                coordinate: batch.coordinate,
                effectiveStart: start,
                effectiveEnd: end,
                replayToken: token,
                firstReceipt: receipt.encoded()
            )
            try await journal.prepareSensorKitBatch(from: checkpoint, nextCursor: receipt.encoded(), evidence: evidence)
        } else {
            _ = try await journal.stage(from: checkpoint, nextCursor: receipt.encoded(), payloads: [])
        }
    }

    func checkSession() async throws {
        try Task.checkCancellation()
        do {
            try await validateSession()
        } catch {
            try Task.checkCancellation()
            throw AcquisitionError.authenticationRequired
        }
        try Task.checkCancellation()
    }

    func registration(for localID: UUID) async throws -> (Components.Schemas.ParticipantSourceRegistration, UUID) {
        let setup = try await journal.sourceSetup(for: localID)
        guard let registration = setup.binding, !registration.isRevoked,
              registration.source.repositoryKind == .sensorkit,
              let sourceID = UUID(uuidString: registration.source.id) else {
            throw EventDeliveryJournal.JournalError.sourceRevoked
        }
        return (registration, sourceID)
    }
}
