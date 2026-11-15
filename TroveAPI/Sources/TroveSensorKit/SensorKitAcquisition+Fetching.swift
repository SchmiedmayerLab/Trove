//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

#if os(iOS)

import Foundation
import GroveFHIRContract
import GroveSensorKit
import GroveSensorKitFHIR
import SensorKit
import TroveAPIClient


extension SensorKitAcquisition {
    /// Collects exact sleep bounds and native session identifiers, retaining whole overlapping sessions.
    @available(iOS 26, *)
    public func catchUpSleepSessions(
        localID: UUID, sensorKit: GroveSensorKit.SensorKit, application: ApplicationDevice, host: HostDevice
    ) async throws -> Bool {
        try await catchUp(localID: localID, sensorKit: sensorKit, sensor: .sleepSessions) { batch, queryID in
            _ = try await self.collectSleepSessions(batch, localID: localID, queryID: queryID, application: application, host: host)
        }
    }

    /// A bounded pass through Grove's lazy acquisition sequence, under the retained enrollment policy.
    /// Native cursors belong to the registered participant source and survive account switches independently.
    public func catchUpOnWrist(
        localID: UUID, sensorKit: GroveSensorKit.SensorKit, application: ApplicationDevice, host: HostDevice
    ) async throws -> Bool {
        try await catchUp(localID: localID, sensorKit: sensorKit, sensor: .onWrist) { batch, queryID in
            _ = try await self.collectOnWrist(batch, localID: localID, queryID: queryID, application: application, host: host)
        }
    }

    /// Collects whole overlapping visit intervals using the existing account journal and native namespace.
    public func catchUpVisits(
        localID: UUID, sensorKit: GroveSensorKit.SensorKit, application: ApplicationDevice, host: HostDevice
    ) async throws -> Bool {
        try await catchUp(localID: localID, sensorKit: sensorKit, sensor: .visits) { batch, queryID in
            _ = try await self.collectVisits(batch, localID: localID, queryID: queryID, application: application, host: host)
        }
    }

    /// Collects complete messages-usage report intervals and all public count facts.
    public func catchUpMessagesUsage(
        localID: UUID, sensorKit: GroveSensorKit.SensorKit, application: ApplicationDevice, host: HostDevice
    ) async throws -> Bool {
        try await catchUp(localID: localID, sensorKit: sensorKit, sensor: .messagesUsage) { batch, queryID in
            _ = try await self.collectMessagesUsage(batch, localID: localID, queryID: queryID, application: application, host: host)
        }
    }

    /// Collects complete phone-usage report intervals and all public count/duration facts.
    public func catchUpPhoneUsage(
        localID: UUID, sensorKit: GroveSensorKit.SensorKit, application: ApplicationDevice, host: HostDevice
    ) async throws -> Bool {
        try await catchUp(localID: localID, sensorKit: sensorKit, sensor: .phoneUsage) { batch, queryID in
            _ = try await self.collectPhoneUsage(batch, localID: localID, queryID: queryID, application: application, host: host)
        }
    }

    func catchUp<Sample: SensorKitSampleProtocol>(
        localID: UUID,
        sensorKit: GroveSensorKit.SensorKit,
        sensor: Sensor<Sample>,
        ecgProcessingLimits: SensorKitECGProcessingLimits? = nil,
        collect: @Sendable (GroveSensorKit.SensorKit.AnchoredBatch<Sample.SafeRepresentation>, UUID) async throws -> Void
    ) async throws -> Bool {
        guard !fetching else { throw AcquisitionError.alreadyCollecting }
        fetching = true
        defer { fetching = false }
        try await checkSession()
        let setup = try await journal.sourceSetup(for: localID)
        guard let registration = setup.binding, !registration.isRevoked,
              registration.source.repositoryKind == .sensorkit,
              let sourceID = UUID(uuidString: registration.source.id),
              let entry = SensorKitCatalog.current.entry(for: sensor) else { throw AcquisitionError.invalidBatch }
        let profiles = try Self.requiredProfiles(for: entry)
        guard let profile = profiles.first else { throw AcquisitionError.invalidBatch }
        let state = try await journal.collectionState()
        guard let snapshot = try state.snapshot?.active(),
              snapshot.permitsSensorKitAcquisition(sourceTypeIdentifier: entry.sourceToken) else {
            throw ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized
        }
        let starts = profiles.compactMap { snapshot.queryStart(for: $0, sourceTypeIdentifier: entry.sourceToken) }
        guard starts.count == profiles.count, let initialStart = starts.max() else {
            throw ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized
        }
        try await checkSession()
        guard try await replayHistory(
            context: ReplayContext(
                sourceID: sourceID, sourceToken: entry.sourceToken, profile: profile, state: state, authority: snapshot.authorityFingerprint()
            ),
            sensorKit: sensorKit,
            sensor: sensor,
            ecgProcessingLimits: ecgProcessingLimits ?? .init(),
            collect: collect
        ) else { return false }
        var pages = 0
        let batches = try await sensorKit.fetchAnchored(
            sensor,
            acquisitionNamespace: sourceID,
            batchSize: .numberOfSamples(128),
            initialStartDate: initialStart,
            ecgProcessingLimits: ecgProcessingLimits
        )
        for try await batch in batches {
            try await checkSession()
            let query = try await partitionQuery(sourceID: sourceID, sourceToken: entry.sourceToken, deviceProductType: batch.info.device.productType)
            try await collect(batch, query)
            pages += 1
            if pages == 8 {
                return false
            }
        }
        return true
    }

    func partitionQuery(
        sourceID: UUID, sourceToken: String, deviceProductType: String, replayAuthority: String? = nil
    ) async throws -> UUID {
        let definition = try SensorKitQueryDefinition(
            sourceToken: sourceToken, deviceProductType: deviceProductType, replayAuthority: replayAuthority
        )
        let queries = try await journal.checkpoints(for: sourceID)
        let matches = queries.filter { (try? SensorKitQueryDefinition(encoded: $0.queryDefinition)) == definition }
        guard matches.count <= 1 else { throw EventDeliveryJournal.JournalError.queryConflict }
        if let existing = matches.first {
            return existing.queryID
        }
        try await checkSession()
        let queryID = UUID()
        _ = try await journal.createQuery(for: sourceID, queryID: queryID, definition: definition.encoded())
        return queryID
    }
}

#endif
