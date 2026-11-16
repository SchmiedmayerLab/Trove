//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveHealthKit
import GroveSensorKit
import HealthKit
import TroveAPIClient
import TroveHealthKit


/// One serialized operation with a captured account. The model owns cancellation and journal exclusion.
@MainActor
struct HealthDataSession {
    let api: TroveAPIModule
    let healthKit: GroveHealthKit.HealthKit
    let sensorKit: GroveSensorKit.SensorKit
    let session: KeycloakSessionSnapshot

    func run(_ action: HealthDataModel.Action) async throws -> HealthDataStatus {
        try checkSession()
        let scope = EventDeliveryJournal.Scope(
            backend: Config.apiBaseURL.absoluteString, issuer: session.issuer.absoluteString, subject: session.subject
        )
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        guard let journal = try await HealthDataStorage.open(scope: scope, root: root, create: action == .setUp) else {
            return .notSetUp
        }
        do {
            try checkSession()
            let result = try await perform(action, journal: journal)
            await journal.close()
            try checkSession()
            return result
        } catch {
            await journal.close()
            throw error
        }
    }

    private func perform(_ action: HealthDataModel.Action, journal: EventDeliveryJournal) async throws -> HealthDataStatus {
        let refreshed = try await refreshPlansIfNeeded(action, journal: journal)
        var statuses: [HealthDataStatus] = []
        if HKHealthStore.isHealthDataAvailable(), let status = try await performHealthKit(action, journal: journal) {
            statuses.append(status)
        }
        if GroveSensorKit.SensorKit.isAvailable {
            if let status = try await performSensorKit(action, journal: journal) { statuses.append(status) }
        } else if try await journal.collectionState().snapshot?.active().permitsSensorKitAcquisition == true {
            statuses.append(.sensorConfigurationRequired)
        }
        try checkSession()
        // Both adapters stage into one journal before its one shared upload/recovery pass.
        if action == .sync {
            let drainer = try api.makeDeliveryDrainer(journal: journal, for: session)
            _ = try await drainer.drain(limit: 128)
            _ = try await journal.pruneDelivered()
        }
        let pending = try await journal.pendingDeliveryIDs(limit: 128)
        for id in pending {
            if case .blocked = try await journal.status(for: id) {
                return .blocked
            }
        }
        return HealthDataStatus.combining(statuses, pending: !pending.isEmpty, synchronized: action == .sync && refreshed)
    }

    private func performSensorKit(_ action: HealthDataModel.Action, journal: EventDeliveryJournal) async throws -> HealthDataStatus? {
        do {
            return try await SensorDataSession(api: api, sensorKit: sensorKit, session: session).perform(action, journal: journal)
        } catch EventDeliveryJournal.JournalError.capacityExceeded {
            return .storageFull
        } catch ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized {
            return .notAuthorized
        } catch EventDeliveryJournal.JournalError.sourceRevoked {
            return .revoked
        }
    }

    private func refreshPlansIfNeeded(_ action: HealthDataModel.Action, journal: EventDeliveryJournal) async throws -> Bool {
        guard action == .setUp || action == .sync else {
            return false
        }
        do {
            try await api.refreshCollectionPlans(journal: journal, for: session)
            try checkSession()
            return true
        } catch ParticipantCollectionRefresh.RefreshError.unavailable where action == .sync {
            try checkSession()
            return false
        }
    }

    private func performHealthKit(_ action: HealthDataModel.Action, journal: EventDeliveryJournal) async throws -> HealthDataStatus? {
        let acquisition = try api.makeHealthKitAcquisition(journal: journal, for: session)
        var sources = try await journal.sourceSetups().filter {
            $0.binding?.source.repositoryKind == .healthkit || (try? HealthKitQueryDefinition(bytes: $0.queryDefinition)) != nil
        }
        if sources.isEmpty, try await requestedStreams(journal).isEmpty {
            return nil
        }
        try checkSession()
        guard sources.count <= 1 else { throw EventDeliveryJournal.JournalError.sourceConflict }
        if action == .setUp, sources.isEmpty {
            let definition = try await acquisition.prepareQueryDefinition()
            try checkSession()
            sources = [try await journal.createSource(localID: UUID(), queryDefinition: definition)]
        }
        guard let source = sources.first else {
            return .notSetUp
        }
        if action == .refresh {
            return try await queueStatus(journal, source: source)
        }
        if action == .setUp {
            let restored = try await api.synchronizeSource(localID: source.localID, journal: journal, for: session)
            return try await queueStatus(journal, source: restored)
        }
        if action == .requestAccess {
            _ = try await acquisition.prepareQueryDefinition()
            try checkSession()
            guard source.binding != nil, source.binding?.isRevoked != true else {
                return .revoked
            }
            let streams = try await requestedStreams(journal)
            let types = try streams.map { try HealthKitAcquisition.sampleType(for: $0) as HKObjectType }
            try await healthKit.askForAuthorization(for: .init(read: types))
            try checkSession()
            return .permissionRequested
        }
        return try await collect(action, acquisition: acquisition, source: source, journal: journal)
    }

    private func collect(
        _ action: HealthDataModel.Action,
        acquisition: HealthKitAcquisition,
        source: EventDeliveryJournal.SourceSetup,
        journal: EventDeliveryJournal
    ) async throws -> HealthDataStatus {
        // Background observer capture is entirely local. Foreground sync refreshes once;
        // an unavailable network cannot prevent capture under a previously accepted plan.
        let refreshed = action == .sync ? try await refreshAuthority(journal, localID: source.localID) : false
        try checkSession()
        let currentSource = try await journal.sourceSetup(for: source.localID)
        var progress = HealthKitAcquisition.Progress.caughtUp
        var collectionStatus: HealthDataStatus?
        do {
            if currentSource.binding?.isRevoked == true { throw EventDeliveryJournal.JournalError.sourceRevoked }
            if try await hasRequestedAccess(journal) {
                try checkSession()
                progress = try await acquisition.catchUp(
                    localID: source.localID, healthKit: healthKit, reviewDocuments: action == .reviewDocuments
                )
                if try await requestedStreams(journal).isEmpty { collectionStatus = .notAuthorized }
            } else {
                collectionStatus = .permissionNeeded
            }
        } catch EventDeliveryJournal.JournalError.capacityExceeded {
            // Preserve the uncommitted page. Delivery can free space without resetting its anchor.
            progress = .needsAnotherPass
        } catch ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized {
            collectionStatus = .notAuthorized
        } catch EventDeliveryJournal.JournalError.sourceRevoked {
            collectionStatus = .revoked
        }
        let status = try await queueStatus(journal, source: currentSource, finished: action == .sync && refreshed, progress: progress)
        if status == .blocked {
            return status
        }
        if let collectionStatus {
            return collectionStatus
        }
        return action == .sync && !refreshed && status == .ready ? .unavailable : status
    }

    private func refreshAuthority(_ journal: EventDeliveryJournal, localID: UUID) async throws -> Bool {
        do {
            _ = try await api.synchronizeSource(localID: localID, journal: journal, for: session)
            try checkSession()
            return true
        } catch SourceRegistration.RegistrationError.unavailable {
            try checkSession()
            return false
        } catch SourceRegistration.RegistrationError.rejected(let status) where status == 429 || status >= 500 {
            try checkSession()
            return false
        } catch ParticipantCollectionRefresh.RefreshError.unavailable {
            try checkSession()
            return false
        }
    }

    private func requestedStreams(_ journal: EventDeliveryJournal) async throws -> [HealthKitQueryDefinition.Stream] {
        let state = try await journal.collectionState()
        return try state.snapshot?.active().acquisitionStreams ?? []
    }

    private func hasRequestedAccess(_ journal: EventDeliveryJournal) async throws -> Bool {
        let types = try await requestedStreams(journal).map { stream in
            try HealthKitAcquisition.sampleType(for: stream) as HKObjectType
        }
        return await healthKit.didAskForAuthorization(toRead: Set(types))
    }

    private func queueStatus(
        _ journal: EventDeliveryJournal,
        source: EventDeliveryJournal.SourceSetup,
        finished: Bool = false,
        progress: HealthKitAcquisition.Progress = .caughtUp
    ) async throws -> HealthDataStatus {
        if source.binding?.isRevoked == true {
            return .revoked
        }
        let pending = try await journal.pendingDeliveryIDs(limit: 128)
        for id in pending {
            if case .blocked = try await journal.status(for: id) {
                return .blocked
            }
        }
        if progress == .needsAnotherPass {
            return .catchUpPending
        }
        return pending.isEmpty ? (finished ? .syncFinished : .ready) : .waiting
    }

    private func checkSession() throws {
        try Task.checkCancellation()
        try api.validateSession(session)
    }
}
