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
import GroveHealthKitFHIR
import HealthKit
import TroveAPIClient


/// One bounded acquisition pass. The caller owns scheduling, permissions and the captured session;
/// the journal owns the only durable key, anchor and delivery queue.
public struct HealthKitAcquisition: Sendable {
    /// Progress of one atomic query page, before consent filtering removes individual samples.
    public struct Page: Sendable {
        public let eventIDs: [UUID]
        public let changeCount: Int

        /// Only an empty HealthKit delta establishes that this query reached its current end.
        public var isCaughtUp: Bool { changeCount == 0 }
    }

    public enum Progress: Sendable, Equatable { case caughtUp, needsAnotherPass }

    public enum AcquisitionError: Error, Equatable {
        case authenticationRequired
        case invalidQueryDefinition
        case unsupportedDelta
        case documentReviewRequired
    }

    struct Delta: Sendable {
        let added: [HKSample]
        let deletedIDs: [UUID]
        let nextAnchor: QueryAnchor
        let readHeartbeatSeries: @Sendable (HKHeartbeatSeriesSample) async throws -> HealthKitRecordingFile
        let readDocument: @Sendable (HKSample) async throws -> HealthKitRecordingFile
        let readRoute: @Sendable (HKWorkoutRoute) async throws -> HealthKitRecordingFile

        init(
            added: [HKSample],
            deletedIDs: [UUID],
            nextAnchor: QueryAnchor,
            readHeartbeatSeries: @escaping @Sendable (HKHeartbeatSeriesSample) async throws -> HealthKitRecordingFile = { _ in
                throw AcquisitionError.unsupportedDelta
            },
            readDocument: @escaping @Sendable (HKSample) async throws -> HealthKitRecordingFile = { _ in throw AcquisitionError.unsupportedDelta },
            readRoute: @escaping @Sendable (HKWorkoutRoute) async throws -> HealthKitRecordingFile = { _ in throw AcquisitionError.unsupportedDelta }
        ) {
            self.added = added
            self.deletedIDs = deletedIDs
            self.nextAnchor = nextAnchor
            self.readHeartbeatSeries = readHeartbeatSeries
            self.readDocument = readDocument
            self.readRoute = readRoute
        }
    }

    struct Selection: Sendable {
        let queryID: UUID
        let state: ParticipantCollectionState
    }

    /// One atomic journal page, including independently authorized companion records.
    static let maximumPageOutputs = 128

    let journal: EventDeliveryJournal
    let scope: EventDeliveryJournal.Scope
    let validateSession: @Sendable () async throws -> Void

    public init(
        journal: EventDeliveryJournal,
        scope: EventDeliveryJournal.Scope,
        validateSession: @escaping @Sendable () async throws -> Void
    ) throws {
        guard journal.scope == scope else { throw EventDeliveryJournal.JournalError.wrongScope }
        self.journal = journal
        self.scope = scope
        self.validateSession = validateSession
    }

    /// Persist once through explicit `journal.createSource`; never replace a definition when restoring.
    public static func queryDefinition(start: Date, profile: CollectionObservationProfile = .heartRate) throws -> Data {
        do {
            return try HealthKitQueryDefinition(profile: profile, kind: .live, start: start).encoded()
        } catch {
            throw AcquisitionError.invalidQueryDefinition
        }
    }

    static func catchUp(nextPage: @Sendable () async throws -> Page) async throws -> Progress {
        for _ in 0..<8 {
            try Task.checkCancellation()
            let page = try await nextPage()
            try Task.checkCancellation()
            if page.isCaughtUp {
                return .caughtUp
            }
        }
        return .needsAnotherPass
    }

    /// Uses a previously retained accepted plan, without reading HealthKit or consulting the network.
    /// Initial setup must first complete ParticipantCollectionRefresh; restoring never resets a query.
    public func prepareQueryDefinition(at now: Date = .now) async throws -> Data {
        try await checkSession()
        let state = try await journal.collectionState()
        try await checkSession()
        guard let snapshot = try state.snapshot?.active(at: now), let stream = snapshot.acquisitionStreams.first,
              let start = snapshot.queryStart(forStream: stream) else {
            throw ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized
        }
        return try HealthKitQueryDefinition(stream: stream, kind: .live, start: max(start, now)).encoded()
    }

    /// Uses Grove's caller-owned anchored query. It neither prompts for permission nor enables background collection.
    /// Returned IDs refer to durable events ready for the existing session-bound delivery drainer.
    public func collect(localID: UUID, healthKit: GroveHealthKit.HealthKit) async throws -> Page {
        let maximumRecordingBytes = await journal.recordingByteLimit
        return try await collect(
            localID: localID, application: ApplicationDevice(bundle: .main), host: .current()
        ) { definition, previous in
            try await Self.query(healthKit, definition: definition, anchor: previous, maximumRecordingBytes: maximumRecordingBytes)
        }
    }

    /// Advances at most eight pages, reserving one for each live measurement. Remaining pages visit the
    /// oldest pending query; the durable sweep survives restarts and revisits history for late imports.
    public func catchUp(localID: UUID, healthKit: GroveHealthKit.HealthKit, reviewDocuments: Bool = false) async throws -> Progress {
        let maximumRecordingBytes = await journal.recordingByteLimit
        return try await catchUp(
            localID: localID, application: ApplicationDevice(bundle: .main), host: .current(), reviewDocuments: reviewDocuments
        ) { definition, previous in
            try await Self.query(
                healthKit, definition: definition, anchor: previous, maximumRecordingBytes: maximumRecordingBytes, reviewDocuments: reviewDocuments
            )
        }
    }

    func collect(
        localID: UUID,
        application: ApplicationDevice,
        host: HostDevice,
        selection: Selection? = nil,
        query: @Sendable (HealthKitQueryDefinition, QueryAnchor) async throws -> Delta
    ) async throws -> Page {
        try await checkSession()
        let source = try await journal.sourceSetup(for: localID)
        guard let registration = source.binding, !registration.isRevoked,
              registration.source.repositoryKind == .healthkit, let sourceID = UUID(uuidString: registration.source.id) else {
            throw EventDeliveryJournal.JournalError.sourceRevoked
        }
        let state: ParticipantCollectionState
        if let selection { state = selection.state } else { state = try await journal.collectionState() }
        guard let snapshot = try state.snapshot?.active(), !snapshot.retainedStreams.isEmpty else {
            throw ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized
        }
        let checkpoint = try await journal.collectionCheckpoint(for: sourceID, state: state, queryID: selection?.queryID)
        let definition = try HealthKitQueryDefinition(bytes: checkpoint.queryDefinition)
        guard snapshot.permitsAcquisition(stream: definition.stream)
                || (snapshot.permitsRetractions(stream: definition.stream) && checkpoint.cursor != nil) else {
            throw ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized
        }
        let anchor = try checkpoint.cursor.map { try JSONDecoder().decode(QueryAnchor.self, from: $0) } ?? QueryAnchor()
        let privacy = try await journal.identityScope(for: sourceID)
        try await checkSession()
        let delta = try await query(definition, anchor)
        try await checkSession()
        let changeCount = delta.added.count + delta.deletedIDs.count
        guard changeCount <= Self.maximumPageOutputs, delta.nextAnchor != QueryAnchor(),
              changeCount == 0 || delta.nextAnchor != anchor else {
            throw AcquisitionError.unsupportedDelta
        }
        let exporter = try Self.exporter(
            source: registration.source, privacy: privacy, application: application, host: host, stream: definition.stream
        )
        let selected = try await permittedChanges(delta, stream: definition.stream, checkpoint: checkpoint, snapshot: snapshot)
        let prepared = try await preparePage(
            selected,
            checkpoint: checkpoint,
            snapshot: snapshot,
            exporter: exporter,
            configuration: Self.conversionConfiguration(application: application, host: host)
        )
        let cursor = try JSONEncoder().encode(delta.nextAnchor)
        try await checkSession()
        let ids = try await journal.stage(
            from: checkpoint,
            nextCursor: cursor,
            payloads: prepared.payloads,
            recordingDeclarations: prepared.recordingDeclarations,
            observedDeletions: delta.deletedIDs,
            queryExhausted: changeCount == 0
        )
        try await checkSession()
        return Page(eventIDs: ids, changeCount: changeCount)
    }
}


extension HealthKitAcquisition {
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
}

#endif
