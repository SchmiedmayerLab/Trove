//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Grove
import GroveHealthKit
import SwiftUI
import TroveAPIClient


@MainActor
@Observable
final class HealthDataModel: Module, EnvironmentAccessible {
    enum Action: Equatable { case refresh, setUp, requestAccess, sync, capture }
    enum WakeContext { case foreground, background }

    struct Transport {
        var session: @MainActor () -> KeycloakSessionSnapshot?
        var run: @MainActor (Action, KeycloakSessionSnapshot) async throws -> HealthDataStatus
    }

    @ObservationIgnored @Dependency(TroveAPIModule.self) private var api
    @ObservationIgnored @Dependency(GroveHealthKit.HealthKit.self) private var healthKit
    @ObservationIgnored private let transport: Transport?
    @ObservationIgnored private let waitForCaptureDeadline: @Sendable () async -> Void
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var operationSession: KeycloakSessionSnapshot?
    @ObservationIgnored private var operationAction: Action?
    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var session: KeycloakSessionSnapshot?
    private var operationID: UUID?
    private var storedStatus: HealthDataStatus = .signedOut

    var status: HealthDataStatus { currentSession == session && session != nil ? storedStatus : .signedOut }
    var isBusy: Bool { currentSession == operationSession && operationSession != nil && operationID != nil }
    var sessionSnapshot: KeycloakSessionSnapshot? { currentSession }
    var needsAutomaticRetry: Bool { isBusy || [.waiting, .catchUpPending, .unavailable].contains(status) }

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
        operationTask?.cancel()
        session = nil
        storedStatus = .signedOut
        resumeWaiters()
    }

    func run(_ action: Action) async {
        guard let captured = currentSession else {
            invalidateSession()
            return
        }
        if session != captured { invalidateSession(); session = captured }
        // Repeated UI actions are ignored, but a replacement account waits for old cleanup.
        guard operationSession != captured || operationID == nil else {
            return
        }
        await perform(action, for: captured)
    }

    /// The observer may acknowledge this wake only after this method returns. A wake
    /// arriving during a query needs a subsequent query, not a join on its earlier snapshot.
    func receiveHealthUpdate(for captured: KeycloakSessionSnapshot, context: WakeContext) async {
        guard !Task.isCancelled, currentSession == captured else {
            return
        }
        if session != captured { invalidateSession(); session = captured }
        if context == .background, operationAction == .sync {
            // Preserve uncertain delivery in the journal; capture must not sit behind an upload backlog.
            operationTask?.cancel()
        }
        let waitForDeadline = waitForCaptureDeadline
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.perform(.capture, for: captured) }
            group.addTask { await waitForDeadline() }
            await group.next()
            group.cancelAll()
            // Structured scope waits for journal cleanup, even when the deadline wins.
            // Twenty seconds is our cancellation budget, not an OS execution guarantee.
        }
    }

    private func perform(_ action: Action, for captured: KeycloakSessionSnapshot) async {
        while operationTask != nil, currentSession == captured, !Task.isCancelled {
            await waitForOperation(for: captured)
        }
        guard !Task.isCancelled, currentSession == captured, session == captured else {
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
                result = try await HealthDataSession(api: api, healthKit: healthKit, session: captured).run(action)
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
