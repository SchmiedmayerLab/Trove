//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Grove
import GroveHealthKit
import GroveSensorKit
import SwiftUI
import TroveAPIClient


@MainActor
@Observable
final class HealthDataModel: Module, EnvironmentAccessible {
    enum Action: Equatable { case refresh, setUp, requestAccess, reviewDocuments, sync, capture }
    enum WakeContext { case foreground, background }

    struct Transport {
        var session: @MainActor () -> KeycloakSessionSnapshot?
        var run: @MainActor (Action, KeycloakSessionSnapshot) async throws -> HealthDataStatus
        var savedCollections: @MainActor (KeycloakSessionSnapshot) async throws -> [ParticipantCollectionState.Collection] = { _ in [] }
        var stopCollection: @MainActor (String, KeycloakSessionSnapshot) async throws -> Void = { _, _ in
            throw EventDeliveryJournal.JournalError.invalidConfiguration
        }
    }

    @ObservationIgnored @Dependency(TroveAPIModule.self) private var api
    @ObservationIgnored @Dependency(GroveHealthKit.HealthKit.self) private var healthKit
    @ObservationIgnored @Dependency(GroveSensorKit.SensorKit.self) private var sensorKit
    @ObservationIgnored private let transport: Transport?
    @ObservationIgnored private let waitForCaptureDeadline: @Sendable () async -> Void
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var operationSession: KeycloakSessionSnapshot?
    @ObservationIgnored private var operationAction: Action?
    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var session: KeycloakSessionSnapshot?
    private var operationID: UUID?
    private var collectionGeneration = UUID()
    private var pendingWithdrawal: KeycloakSessionSnapshot?
    private var storedStatus: HealthDataStatus = .signedOut
    private var settingsSession: KeycloakSessionSnapshot?
    private var settingsRequestID: UUID?
    private var storedSettings: LoadingState<[ParticipantCollectionState.Collection]> = .idle

    var status: HealthDataStatus { currentSession == session && session != nil ? storedStatus : .signedOut }
    var isBusy: Bool {
        currentSession != nil && (currentSession == pendingWithdrawal || currentSession == operationSession && operationID != nil)
    }
    var isReviewingDocuments: Bool { isBusy && operationAction == .reviewDocuments }
    var sessionSnapshot: KeycloakSessionSnapshot? { currentSession }
    var savedCollections: LoadingState<[ParticipantCollectionState.Collection]> {
        currentSession != nil && currentSession == settingsSession ? storedSettings : .idle
    }
    var needsAutomaticRetry: Bool { isBusy || [.waiting, .catchUpPending, .refreshNeeded, .unavailable].contains(status) }

    private var currentSession: KeycloakSessionSnapshot? {
        if let transport {
            return transport.session()
        }
        return api.sessionSnapshot
    }

    init(
        transport: Transport? = nil,
        waitForCaptureDeadline: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(20)) }
    ) {
        self.transport = transport
        self.waitForCaptureDeadline = waitForCaptureDeadline
    }

    func invalidateSession() {
        collectionGeneration = UUID()
        operationTask?.cancel()
        session = nil
        storedStatus = .signedOut
        if settingsSession != currentSession {
            settingsSession = nil
            settingsRequestID = nil
            storedSettings = .idle
        }
        resumeWaiters()
    }

    /// A read-only local operation; failure must not be presented as an empty collection plan.
    func refreshCollectionSettings() async {
        guard let captured = currentSession else {
            return
        }
        if settingsSession != captured { storedSettings = .idle }
        settingsSession = captured
        let requestID = UUID()
        settingsRequestID = requestID
        storedSettings.beginLoading()
        do {
            let collections: [ParticipantCollectionState.Collection]
            if let transport { collections = try await transport.savedCollections(captured) } else {
                collections = try await api.savedCollections(for: captured)
            }
            guard currentSession == captured, settingsRequestID == requestID else {
                return
            }
            if Task.isCancelled { storedSettings.cancelLoading() } else { storedSettings.resolve(with: collections) }
        } catch {
            guard currentSession == captured, settingsRequestID == requestID else {
                return
            }
            if Task.isCancelled { storedSettings.cancelLoading() } else { storedSettings.reject(with: error) }
        }
    }

    /// Exclude new passes while the current writer closes, then persist the local stop before HTTP.
    func stopCollection(enrollmentId: String, for captured: KeycloakSessionSnapshot) async throws {
        guard currentSession == captured else { throw CancellationError() }
        guard pendingWithdrawal != captured else { throw EventDeliveryJournal.JournalError.invalidConfiguration }
        if session != captured { invalidateSession(); session = captured }
        pendingWithdrawal = captured
        // A queued observer must remain invalid even after withdrawal finishes and clears the busy flag.
        collectionGeneration = UUID()
        operationTask?.cancel()
        defer {
            if pendingWithdrawal == captured { pendingWithdrawal = nil }
            resumeWaiters()
        }
        while operationTask != nil, currentSession == captured, !Task.isCancelled {
            await waitForOperation(for: captured)
        }
        try Task.checkCancellation()
        guard currentSession == captured else { throw CancellationError() }
        try await persistStop(enrollmentId: enrollmentId, for: captured)
        guard currentSession == captured else { throw CancellationError() }
        session = captured
        storedStatus = .refreshNeeded
    }

    private func persistStop(enrollmentId: String, for captured: KeycloakSessionSnapshot) async throws {
        if let transport {
            try await transport.stopCollection(enrollmentId, captured)
        } else {
            try await api.stopCollection(enrollmentId: enrollmentId, for: captured)
            guard currentSession == captured else { throw CancellationError() }
            // Stop device recording immediately after the durable local withdrawal.
            // A later pass can restart only sensors still covered by other active studies.
            storedStatus = .refreshNeeded
            do {
                try await SensorDataConfiguration.stopRecording()
            } catch {
                if currentSession == captured { storedStatus = .blocked }
                throw error
            }
        }
    }

    func cancelDocumentReview() {
        guard isReviewingDocuments else {
            return
        }
        storedStatus = .documentReviewCancelled
        operationTask?.cancel()
    }

    func run(_ action: Action) async {
        guard let captured = currentSession else {
            invalidateSession()
            return
        }
        guard pendingWithdrawal != captured else {
            return
        }
        if session != captured { invalidateSession(); session = captured }
        // Repeated UI actions are ignored, but a replacement account waits for old cleanup.
        guard operationSession != captured || operationID == nil else {
            return
        }
        await perform(action, for: captured, generation: collectionGeneration)
    }

    /// The observer may acknowledge this wake only after this method returns. A wake
    /// arriving during a query needs a subsequent query, not a join on its earlier snapshot.
    func receiveHealthUpdate(for captured: KeycloakSessionSnapshot, context: WakeContext) async {
        guard !Task.isCancelled, currentSession == captured, pendingWithdrawal != captured else {
            return
        }
        if session != captured { invalidateSession(); session = captured }
        if context == .background, operationAction == .sync {
            // Preserve uncertain delivery in the journal; capture must not sit behind an upload backlog.
            operationTask?.cancel()
        }
        let waitForDeadline = waitForCaptureDeadline
        let generation = collectionGeneration
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.perform(.capture, for: captured, generation: generation) }
            group.addTask { await waitForDeadline() }
            await group.next()
            group.cancelAll()
            // Structured scope waits for journal cleanup, even when the deadline wins.
            // Twenty seconds is our cancellation budget, not an OS execution guarantee.
        }
    }

    private func perform(_ action: Action, for captured: KeycloakSessionSnapshot, generation: UUID) async {
        while operationTask != nil, currentSession == captured, !Task.isCancelled {
            await waitForOperation(for: captured)
        }
        guard !Task.isCancelled, currentSession == captured, session == captured,
              collectionGeneration == generation, pendingWithdrawal != captured else {
            return
        }
        let identifier = UUID()
        operationID = identifier
        operationSession = captured
        operationAction = action
        let task = Task { @MainActor in
            defer { finishOperation(identifier) }
            await execute(action, for: captured)
        }
        operationTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func execute(_ action: Action, for captured: KeycloakSessionSnapshot) async {
        let result: HealthDataStatus
        do {
            try Task.checkCancellation()
            if let transport {
                result = try await transport.run(action, captured)
            } else {
                result = try await HealthDataSession(api: api, healthKit: healthKit, sensorKit: sensorKit, session: captured).run(action)
            }
        } catch is CancellationError {
            return
        } catch {
            result = HealthDataStatus(error: error)
        }
        guard !Task.isCancelled, currentSession == captured, session == captured else {
            return
        }
        storedStatus = result
    }

    private func waitForOperation(for captured: KeycloakSessionSnapshot) async {
        let identifier = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || operationTask == nil || currentSession != captured {
                    continuation.resume()
                } else {
                    waiters[identifier] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: identifier)?.resume()
            }
        }
    }

    private func finishOperation(_ identifier: UUID) {
        guard operationID == identifier else {
            return
        }
        operationTask = nil
        operationID = nil
        operationSession = nil
        operationAction = nil
        resumeWaiters()
    }

    private func resumeWaiters() {
        let continuations = Array(waiters.values)
        waiters.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}
