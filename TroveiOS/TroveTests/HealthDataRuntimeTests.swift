//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Observation
import Testing
@testable import Trove
import UIKit


@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HealthDataRuntimeTests {
    @Test
    func launchInstallsWithoutAnAccountAndStopsItsOwnedObservation() async throws {
        let fixture = try Fixture(signedIn: false)
        let runtime = fixture.runtime()
        runtime.start(notificationCenter: NotificationCenter())
        #expect(fixture.installations == 1 && fixture.actions.isEmpty)
        await fixture.wake?()
        #expect(fixture.actions.isEmpty)
        await runtime.stop()
        #expect(fixture.closedObservations == 1)
        runtime.start(notificationCenter: NotificationCenter())
        await fixture.wake?()
        #expect(fixture.installations == 1 && fixture.actions.isEmpty)
    }

    @Test
    func truncatedPassWaitsBeforeContinuingRatherThanSpinning() async throws {
        let fixture = try Fixture()
        let runtime = fixture.runtime()
        runtime.start(notificationCenter: NotificationCenter())
        await fixture.waitForCall()
        fixture.finish(.catchUpPending, at: 0)
        await fixture.waitForDelay()
        #expect(fixture.actions == [.sync])
        fixture.releaseDelay(at: 0)
        await fixture.waitForCall()
        #expect(fixture.actions == [.sync, .sync])
        fixture.finish(.syncFinished, at: 1)
        await runtime.stop()
    }

    @Test
    func registrationFailureWaitsBeforeInstallingAnotherObserver() async throws {
        let fixture = try Fixture()
        fixture.active = false
        fixture.failNextObservation = true
        let runtime = fixture.runtime()
        runtime.start(notificationCenter: NotificationCenter())
        // Registration completes asynchronously after the application becomes active.
        fixture.active = true
        await fixture.waitForDelay()
        #expect(fixture.installations == 1 && fixture.closedObservations == 1)
        #expect(fixture.actions.isEmpty)
        fixture.releaseDelay(at: 0)
        await fixture.waitForCall()
        #expect(fixture.installations == 2 && fixture.actions == [.sync])
        fixture.finish(.syncFinished, at: 0)
        await runtime.stop()
        #expect(fixture.closedObservations == 2)
    }

    @Test
    func lifecycleNotificationsStartAndCancelForegroundDelivery() async throws {
        let fixture = try Fixture()
        fixture.active = false
        let center = NotificationCenter()
        let runtime = fixture.runtime()
        runtime.start(notificationCenter: center)
        fixture.active = true
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await fixture.waitForCall()
        #expect(fixture.actions == [.sync])
        fixture.active = false
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await fixture.waitForCancellation()
        fixture.finish(.syncFinished, at: 0)
        await runtime.stop()
        #expect(fixture.actions == [.sync])
    }

    @Test
    func backgroundWakeCapturesWithoutStartingAnotherUpload() async throws {
        let fixture = try Fixture()
        let runtime = fixture.runtime()
        runtime.start(notificationCenter: NotificationCenter())
        await fixture.waitForCall()
        fixture.active = false
        runtime.foregroundChanged()
        await fixture.waitForCancellation()
        let wake = Task { await fixture.wake?() }
        fixture.finish(.syncFinished, at: 0)
        await fixture.waitForCall()
        #expect(fixture.actions == [.sync, .capture])
        fixture.finish(.waiting, at: 1)
        await wake.value
        #expect(fixture.actions == [.sync, .capture])
        await runtime.stop()
    }

    @Test
    func accountReplacementWaitsForOldCleanupBeforeStartingTheNewSession() async throws {
        let fixture = try Fixture()
        let original = try #require(fixture.session)
        let runtime = fixture.runtime()
        runtime.start(notificationCenter: NotificationCenter())
        await fixture.waitForCall()
        let replacement = try Fixture.snapshot()
        fixture.session = replacement
        await fixture.waitForCancellation()
        #expect(fixture.sessions == [original])
        fixture.finish(.syncFinished, at: 0)
        await fixture.waitForCall()
        #expect(fixture.sessions == [original, replacement])
        fixture.finish(.syncFinished, at: 1)
        await runtime.stop()
    }

    @Test
    func signingOutCancelsDeliveryAndLaterWakesDoNotCollect() async throws {
        let fixture = try Fixture()
        let runtime = fixture.runtime()
        runtime.start(notificationCenter: NotificationCenter())
        await fixture.waitForCall()
        fixture.session = nil
        await fixture.waitForCancellation()
        fixture.finish(.syncFinished, at: 0)
        await fixture.wake?()
        await runtime.stop()
        #expect(fixture.actions == [.sync])
    }
}


extension HealthDataRuntimeTests {
    @MainActor
    @Observable
    fileprivate final class Fixture {
        var session: KeycloakSessionSnapshot?
        var active = true
        var installations = 0
        var closedObservations = 0
        var failNextObservation = false
        var actions: [HealthDataModel.Action] = []
        var sessions: [KeycloakSessionSnapshot] = []
        var wake: (@MainActor @Sendable () async -> Void)?
        private var completions: [CheckedContinuation<HealthDataStatus, Never>?] = []
        private var delays: [AsyncStream<Void>.Continuation] = []
        private let calls = AsyncStream<Void>.makeStream()
        private let cancellations = AsyncStream<Void>.makeStream()
        private let delayStarts = AsyncStream<Void>.makeStream()

        init(signedIn: Bool = true) throws { session = signedIn ? try Self.snapshot() : nil }

        static func snapshot() throws -> KeycloakSessionSnapshot {
            .init(generation: UUID(), issuer: try #require(URL(string: "https://identity.example/realm")), subject: UUID().uuidString)
        }

        func runtime() -> HealthDataRuntime {
            let model = HealthDataModel(transport: .init(session: { self.session }, run: { action, session in
                self.actions.append(action)
                self.sessions.append(session)
                let cancelled = self.cancellations.continuation
                return await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        self.completions.append(continuation)
                        self.calls.continuation.yield(())
                    }
                } onCancel: { cancelled.yield(()) }
            }))
            return HealthDataRuntime(model: model, isActive: { self.active }, waitBeforeRetry: { try await self.delay() }) { update in
                self.installations += 1
                self.wake = update
                let shouldFail = self.failNextObservation
                self.failNextObservation = false
                return Task {
                    defer { self.closedObservations += 1 }
                    if shouldFail { throw URLError(.cannotConnectToHost) }
                    let lifetime = AsyncStream<Void>.makeStream()
                    defer { lifetime.continuation.finish() }
                    for await _ in lifetime.stream { }
                }
            }
        }

        func delay() async throws {
            let delay = AsyncStream<Void>.makeStream()
            delays.append(delay.continuation)
            delayStarts.continuation.yield(())
            for await _ in delay.stream { break }
            try Task.checkCancellation()
        }

        func waitForCall() async { for await _ in calls.stream { break } }
        func waitForCancellation() async { for await _ in cancellations.stream { break } }
        func waitForDelay() async { for await _ in delayStarts.stream { break } }
        func releaseDelay(at index: Int) { delays[index].yield(()); delays[index].finish() }

        func finish(_ status: HealthDataStatus, at index: Int) {
            completions[index]?.resume(returning: status)
            completions[index] = nil
        }
    }
}
