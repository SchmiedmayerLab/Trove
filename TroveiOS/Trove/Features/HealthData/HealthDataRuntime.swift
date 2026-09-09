//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Observation
import UIKit


/// App-owned scheduling only. The model owns operation exclusion; the journal owns durable progress.
@MainActor
final class HealthDataRuntime {
    typealias ObserverInstaller = @MainActor (@escaping @MainActor @Sendable () async -> Void) -> Task<Void, any Error>
    private enum State { case idle, running, stopped }

    private let model: HealthDataModel
    private let installObserver: ObserverInstaller
    private let isActive: @MainActor () -> Bool
    private let waitBeforeRetry: @Sendable () async throws -> Void
    private var observation: Task<Void, any Error>?
    private var observationMonitor: Task<Void, Never>?
    private var monitoring: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var state: State = .idle
    private var pendingPass = false
    private var observedSession: KeycloakSessionSnapshot?

    private var started: Bool { state == .running }

    init(
        model: HealthDataModel,
        isActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
        waitBeforeRetry: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(60)) },
        installObserver: @escaping ObserverInstaller
    ) {
        self.model = model
        self.isActive = isActive
        self.waitBeforeRetry = waitBeforeRetry
        self.installObserver = installObserver
    }

    /// Called synchronously by the launch delegate, before any asynchronous session restoration.
    func start(notificationCenter: NotificationCenter = .default) {
        guard state == .idle else {
            return
        }
        state = .running
        observedSession = model.sessionSnapshot
        startObservation()
        let sessions = Observations { [model] in model.sessionSnapshot }
        let statuses = Observations { [model] in model.status }
        let foregrounds = notificationCenter.notifications(named: UIApplication.didBecomeActiveNotification)
        let backgrounds = notificationCenter.notifications(named: UIApplication.didEnterBackgroundNotification)
        monitoring = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor [weak self] in
                    for await session in sessions { self?.sessionChanged(session) }
                }
                group.addTask { @MainActor [weak self] in
                    for await status in statuses where status == .ready || status == .permissionRequested { self?.requestPass() }
                }
                group.addTask { @MainActor [weak self] in
                    for await _ in foregrounds { self?.foregroundChanged() }
                }
                group.addTask { @MainActor [weak self] in
                    for await _ in backgrounds { self?.foregroundChanged() }
                }
            }
        }
        requestPass()
    }

    func stop() async {
        state = .stopped
        observation?.cancel()
        monitoring?.cancel()
        syncTask?.cancel()
        retryTask?.cancel()
        _ = await observation?.result
        await observationMonitor?.value
        await monitoring?.value
        await syncTask?.value
        await retryTask?.value
        observation = nil
        observationMonitor = nil
        monitoring = nil
        syncTask = nil
        retryTask = nil
        pendingPass = false
    }

    func foregroundChanged() {
        if isActive() {
            requestPass()
        } else {
            syncTask?.cancel()
            retryTask?.cancel()
            retryTask = nil
        }
    }

    func requestPass() {
        guard started, isActive(), let session = model.sessionSnapshot else {
            return
        }
        startObservation()
        pendingPass = true
        guard syncTask == nil else {
            return
        }
        if model.isBusy {
            scheduleRetry()
            return
        }
        retryTask?.cancel()
        retryTask = nil
        pendingPass = false
        syncTask = Task { @MainActor [weak self, model] in
            if !Task.isCancelled, model.sessionSnapshot == session { await model.run(.sync) }
            self?.finishedPass(for: session)
        }
    }

    private func sessionChanged(_ session: KeycloakSessionSnapshot?) {
        guard started, session != observedSession else {
            return
        }
        observedSession = session
        syncTask?.cancel()
        retryTask?.cancel()
        retryTask = nil
        model.invalidateSession()
        requestPass()
    }

    private func finishedPass(for session: KeycloakSessionSnapshot) {
        syncTask = nil
        guard started, isActive() else {
            return
        }
        if model.sessionSnapshot != session {
            requestPass()
        } else if pendingPass || model.needsAutomaticRetry {
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard started, isActive(), model.sessionSnapshot != nil, retryTask == nil else {
            return
        }
        let wait = waitBeforeRetry
        retryTask = Task { @MainActor [weak self] in
            do {
                try await wait()
                try Task.checkCancellation()
                self?.retryTask = nil
                self?.requestPass()
            } catch {
                // Cancellation ends this timer; failures wait for the next foreground/session signal.
                if !Task.isCancelled { self?.retryTask = nil }
            }
        }
    }

    private func startObservation() {
        guard started, observation == nil else {
            return
        }
        let task = installObserver { [weak self] in
            guard let self, started, let session = model.sessionSnapshot else {
                return
            }
            await model.receiveHealthUpdate(for: session, context: isActive() ? .foreground : .background)
            requestPass()
        }
        observation = task
        observationMonitor = Task { @MainActor [weak self] in
            _ = await task.result
            self?.observation = nil
            if self?.started == true { self?.scheduleRetry() }
        }
    }

    deinit {
        observation?.cancel()
        observationMonitor?.cancel()
        monitoring?.cancel()
        syncTask?.cancel()
        retryTask?.cancel()
    }
}
