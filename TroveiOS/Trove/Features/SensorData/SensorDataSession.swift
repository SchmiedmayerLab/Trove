//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveSensorKit
import SensorKit
import TroveAPIClient
import TroveSensorKit


/// Participates in HealthDataModel's serialized operation and existing account-scoped journal.
/// Uploads remain the responsibility of the shared delivery drainer after all acquisition finishes.
@MainActor
struct SensorDataSession {
    let api: TroveAPIModule
    let sensorKit: GroveSensorKit.SensorKit
    let session: KeycloakSessionSnapshot

    func perform(_ action: HealthDataModel.Action, journal: EventDeliveryJournal) async throws -> HealthDataStatus? {
        try checkSession()
        let state = try await journal.collectionState()
        let active = try state.snapshot?.active()
        let requested = active.map { snapshot in SensorKitCollectionSource.allCases.filter { $0.isPermitted(by: snapshot) } } ?? []
        let selected = requested.filter { SensorDataConfiguration.sources.contains($0) }
        let sources = try await journal.sourceSetups().filter {
            $0.binding?.source.repositoryKind == .sensorkit || (try? SensorKitSourceDefinition(encoded: $0.queryDefinition)) != nil
        }
        guard sources.count <= 1 else { throw EventDeliveryJournal.JournalError.sourceConflict }
        if !sources.isEmpty {
            for source in SensorDataConfiguration.sources where !selected.contains(source) && source.sensor?.authorizationStatus == .authorized {
                try await source.sensor?.stopRecording()
            }
        }
        guard !selected.isEmpty else {
            if !requested.isEmpty {
                return .sensorConfigurationRequired
            }
            return sources.isEmpty ? nil : .notAuthorized
        }
        var source = sources.first
        if action == .setUp, source == nil {
            source = try await journal.createSource(localID: UUID(), queryDefinition: SensorKitSourceDefinition().encoded())
        }
        guard let existing = source else {
            return .notSetUp
        }
        source = try await refreshedSource(existing, action: action, journal: journal)
        guard source?.binding != nil, source?.binding?.isRevoked != true else {
            return .revoked
        }
        let result = try await collect(action, selected: selected, localID: existing.localID, journal: journal)
        return result == .ready && selected.count != requested.count ? .sensorConfigurationRequired : result
    }

    private func collect(
        _ action: HealthDataModel.Action,
        selected: [SensorKitCollectionSource],
        localID: UUID,
        journal: EventDeliveryJournal
    ) async throws -> HealthDataStatus {
        if action == .requestAccess {
            let result = try await sensorKit.requestAccess(to: selected.compactMap(\.sensor))
            try checkSession()
            guard result.denied.isEmpty else {
                return .permissionNeeded
            }
            for source in selected { try await source.sensor?.startRecording() }
            return .permissionRequested
        }
        guard action == .sync || action == .capture else {
            return .ready
        }
        guard selected.allSatisfy({ $0.sensor?.authorizationStatus == .authorized }) else {
            return .permissionNeeded
        }
        for source in selected { try await source.sensor?.startRecording() }
        try checkSession()
        let acquisition = try SensorKitAcquisition(journal: journal, scope: journal.scope) {
            try await api.validateSession(session)
        }
        var caughtUp = true
        let application = try ApplicationDevice(bundle: .main)
        let host = try HostDevice.current()
        for source in selected {
            let complete = try await source.catchUp(
                acquisition: acquisition, localID: localID, sensorKit: sensorKit, application: application, host: host
            )
            caughtUp = caughtUp && complete
        }
        return caughtUp ? .ready : .catchUpPending
    }

    private func refreshedSource(
        _ source: EventDeliveryJournal.SourceSetup, action: HealthDataModel.Action, journal: EventDeliveryJournal
    ) async throws -> EventDeliveryJournal.SourceSetup {
        guard action == .setUp || action == .sync else {
            return source
        }
        do {
            return try await synchronize(source.localID, journal: journal)
        } catch SourceRegistration.RegistrationError.unavailable where action == .sync {
            try checkSession()
            return source
        } catch SourceRegistration.RegistrationError.rejected(let status) where action == .sync && (status == 429 || status >= 500) {
            try checkSession()
            return source
        }
    }

    private func synchronize(_ localID: UUID, journal: EventDeliveryJournal) async throws -> EventDeliveryJournal.SourceSetup {
        try await SourceRegistration.synchronize(
            journal: journal,
            scope: journal.scope,
            localID: localID,
            client: api.requireClient(for: session),
            repositoryKind: .sensorkit,
            validateSession: { try await api.validateSession(session) }
        )
    }

    private func checkSession() throws {
        try Task.checkCancellation()
        try api.validateSession(session)
    }
}
