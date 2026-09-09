//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveHealthKit
import HealthKit
import TroveAPIClient
import TroveHealthKit


/// One serialized operation with a captured account. The model owns cancellation and journal exclusion.
@MainActor
struct HealthDataSession {
    let api: TroveAPIModule
    let healthKit: GroveHealthKit.HealthKit
    let session: KeycloakSessionSnapshot

    func run(_ action: HealthDataModel.Action) async throws -> HealthDataStatus {
        try checkSession()
        guard HKHealthStore.isHealthDataAvailable() else {
            return .unavailable
        }
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
        let acquisition = try api.makeHeartRateAcquisition(journal: journal, for: session)
        var sources = try await journal.sourceSetups()
        try checkSession()
        guard sources.count <= 1 else { throw EventDeliveryJournal.JournalError.sourceConflict }
        if action == .setUp, sources.isEmpty {
            let definition = try await acquisition.prepareQueryDefinition(enrollmentIDs: enrollmentIDs())
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
            _ = try await acquisition.prepareQueryDefinition(enrollmentIDs: enrollmentIDs())
            let refreshed = try await api.synchronizeSource(localID: source.localID, journal: journal, for: session)
            try checkSession()
            guard refreshed.binding?.revokedAt == nil else {
                return .revoked
            }
            try await healthKit.askForAuthorization(for: .init(read: [HKQuantityType(.heartRate)]))
            try checkSession()
            return .permissionRequested
        }
        return try await collect(action, acquisition: acquisition, source: source, journal: journal)
    }

    private func collect(
        _ action: HealthDataModel.Action,
        acquisition: HeartRateAcquisition,
        source: EventDeliveryJournal.SourceSetup,
        journal: EventDeliveryJournal
    ) async throws -> HealthDataStatus {
        if action == .sync {
            let drainer = try api.makeDeliveryDrainer(journal: journal, for: session)
            _ = try await drainer.drain(limit: 128)
            _ = try await journal.pruneDelivered()
        }
        try checkSession()
        guard source.binding?.revokedAt == nil else {
            return .revoked
        }
        let enrollments = try await enrollmentIDs()
        guard await healthKit.didAskForAuthorization(toRead: SampleType.heartRate) else {
            _ = try await acquisition.prepareQueryDefinition(enrollmentIDs: enrollments)
            return .permissionNeeded
        }
        try checkSession()
        let progress = try await acquisition.catchUp(localID: source.localID, enrollmentIDs: enrollments, healthKit: healthKit)
        if action == .capture {
            return try await queueStatus(journal, source: source, progress: progress)
        }
        let drainer = try api.makeDeliveryDrainer(journal: journal, for: session)
        _ = try await drainer.drain(limit: 128)
        _ = try await journal.pruneDelivered()
        return try await queueStatus(journal, source: source, finished: true, progress: progress)
    }

    private func enrollmentIDs() async throws -> [UUID] {
        try checkSession()
        let enrollments = try await api.requireClient(for: session).getParticipantEnrollments(.init()).ok.body.json
        try checkSession()
        return try enrollments.filter { $0.withdrawnAt == nil }.map {
            guard let id = UUID(uuidString: $0.id) else { throw ParticipantCollectionSnapshot.CollectionError.invalidPlan }
            return id
        }
    }

    private func queueStatus(
        _ journal: EventDeliveryJournal,
        source: EventDeliveryJournal.SourceSetup,
        finished: Bool = false,
        progress: HeartRateAcquisition.Progress = .caughtUp
    ) async throws -> HealthDataStatus {
        if source.binding?.revokedAt != nil {
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
