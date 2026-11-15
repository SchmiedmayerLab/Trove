//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import BackgroundTasks
import GroveSensorKit
import Observation
import TroveSensorKit
import UIKit


/// Supplies SensorKit wake opportunities to the existing serialized collection model.
/// iOS decides when background processing runs; this scheduler does not promise continuous delivery.
@MainActor
final class SensorDataRuntime {
    static let backgroundTaskIdentifier = "org.trove.sensorkit.collection"
    private let model: HealthDataModel
    private let isEnabled: @MainActor () -> Bool
    private var monitoring: Task<Void, Never>?
    private var foregroundPass: Task<Void, Never>?
    private var backgroundPass: Task<Void, Never>?
    private var started = false
    private var registrationAttempted = false
    private var backgroundRegistered = false

    init(model: HealthDataModel, isEnabled: @escaping @MainActor () -> Bool) {
        self.model = model
        self.isEnabled = isEnabled
    }

    func start(notificationCenter: NotificationCenter = .default) {
        guard !started else {
            return
        }
        started = true
        registerBackgroundTask()
        let sessions = Observations { [model] in model.sessionSnapshot }
        let statuses = Observations { [model] in model.status }
        let foregrounds = notificationCenter.notifications(named: UIApplication.didBecomeActiveNotification)
        monitoring = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor [weak self] in
                    for await session in sessions {
                        guard let self else {
                            return
                        }
                        self.foregroundPass?.cancel()
                        self.backgroundPass?.cancel()
                        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
                        try? await SensorDataConfiguration.stopRecording()
                        if session != nil {
                            self.requestPass()
                        }
                    }
                }
                group.addTask { @MainActor [weak self] in
                    for await status in statuses where status == .permissionRequested {
                        self?.requestPass()
                    }
                }
                group.addTask { @MainActor [weak self] in
                    for await _ in foregrounds { self?.requestPass() }
                }
            }
        }
        requestPass()
    }

    private func registerBackgroundTask() {
        guard !registrationAttempted else {
            return
        }
        registrationAttempted = true
        backgroundRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundTaskIdentifier, using: .main
        ) { [weak self] task in
            Task { @MainActor in
                guard let self, let processing = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.runBackground(processing)
            }
        }
    }


    func stop() async {
        started = false
        monitoring?.cancel()
        foregroundPass?.cancel()
        backgroundPass?.cancel()
        await monitoring?.value
        await foregroundPass?.value
        await backgroundPass?.value
        monitoring = nil
        foregroundPass = nil
        backgroundPass = nil
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
    }

    private func requestPass() {
        guard started, isEnabled(), let captured = model.sessionSnapshot else {
            return
        }
        scheduleBackground()
        guard UIApplication.shared.applicationState == .active, foregroundPass == nil else {
            return
        }
        foregroundPass = Task { [weak self, model] in
            await model.run(.sync)
            self?.foregroundPass = nil
            if model.sessionSnapshot != captured { self?.requestPass() }
        }
    }

    private func runBackground(_ task: BGProcessingTask) {
        guard started, isEnabled(), model.sessionSnapshot != nil, backgroundPass == nil else {
            task.setTaskCompleted(success: false)
            return
        }
        scheduleBackground()
        let operation = Task { @MainActor [weak self, model] in
            await model.run(.capture)
            let failed: [HealthDataStatus] = [.blocked, .unavailable, .storageFull, .historyUnavailable, .refreshNeeded]
            task.setTaskCompleted(success: !Task.isCancelled && !failed.contains(model.status))
            self?.backgroundPass = nil
        }
        backgroundPass = operation
        task.expirationHandler = { operation.cancel() }
    }

    private func scheduleBackground() {
        guard backgroundRegistered else {
            return
        }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.earliestBeginDate = Date.now.addingTimeInterval(3600)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        // Scheduling can be unavailable or disabled. The next foreground remains an acquisition opportunity.
        try? BGTaskScheduler.shared.submit(request)
    }

    deinit {
        monitoring?.cancel()
        foregroundPass?.cancel()
        backgroundPass?.cancel()
    }
}
