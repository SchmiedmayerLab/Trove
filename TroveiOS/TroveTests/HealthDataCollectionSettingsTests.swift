//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveLocalization
import Testing
@testable import Trove
import TroveAPIClient


@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HealthDataCollectionSettingsTests {
    @Test
    func localReadDoesNotRunCollectionOrRequireRemoteProfile() async throws {
        let fixture = Fixture()
        defer { fixture.cancelAll() }
        let model = fixture.model()
        let task = Task { await model.refreshCollectionSettings() }
        try await fixture.waitForCount(1)
        fixture.finish([Self.collection(stopped: true)])
        await task.value
        #expect(model.savedCollections.isLoaded)
        #expect(model.savedCollections.value?.first?.isStopped == true)
        #expect(model.savedCollections.value?.first?.plan.title[.enUS] == "Saved Study")
        #expect(fixture.actions.isEmpty)
    }

    @Test(arguments: [false, true])
    func oldAccountResponseCannotReplaceNewSettings(oldFails: Bool) async throws {
        let fixture = Fixture()
        defer { fixture.cancelAll() }
        let model = fixture.model()
        let old = Task { await model.refreshCollectionSettings() }
        try await fixture.waitForCount(1)
        fixture.session = Self.session()
        #expect(model.savedCollections.value == nil)
        let current = Task { await model.refreshCollectionSettings() }
        try await fixture.waitForCount(2)
        // A delayed session callback must not discard the replacement account's active read.
        model.invalidateSession()
        let expected = Self.collection(stopped: false)
        fixture.finish([expected], at: 1)
        await current.value
        if oldFails { fixture.fail() } else { fixture.finish([Self.collection(stopped: true)]) }
        await old.value
        #expect(model.savedCollections.value?.map(\.plan) == [expected.plan])
        #expect(model.savedCollections.isLoaded)
        fixture.session = nil
        #expect(model.savedCollections.value == nil)
    }

    @Test
    func latestLocalReadWinsAndFailurePreservesVisibleSettings() async throws {
        let fixture = Fixture()
        defer { fixture.cancelAll() }
        let model = fixture.model()
        let first = Task { await model.refreshCollectionSettings() }
        try await fixture.waitForCount(1)
        let second = Task { await model.refreshCollectionSettings() }
        try await fixture.waitForCount(2)
        let stopped = Self.collection(stopped: true)
        fixture.finish([stopped], at: 1)
        await second.value
        fixture.finish([Self.collection(stopped: false)])
        await first.value
        #expect(model.savedCollections.value?.map(\.plan) == [stopped.plan])
        let failed = Task { await model.refreshCollectionSettings() }
        try await fixture.waitForCount(3)
        fixture.fail()
        await failed.value
        #expect(model.savedCollections.error != nil && !model.savedCollections.isLoaded)
        #expect(model.savedCollections.value?.map(\.plan) == [stopped.plan])
    }

    @Test
    func failedInitialReadIsDistinctFromAnEmptyPlanAndCancelledRetryDoesNotEraseIt() async throws {
        let fixture = Fixture()
        defer { fixture.cancelAll() }
        let model = fixture.model()
        let failed = Task { await model.refreshCollectionSettings() }
        try await fixture.waitForCount(1)
        fixture.fail()
        await failed.value
        #expect(model.savedCollections.value == nil && model.savedCollections.error != nil)
        let loaded = Task { await model.refreshCollectionSettings() }
        try await fixture.waitForCount(2)
        fixture.finish([])
        await loaded.value
        #expect(model.savedCollections.isLoaded && model.savedCollections.value?.isEmpty == true)
        let cancelled = Task { await model.refreshCollectionSettings() }
        try await fixture.waitForCount(3)
        cancelled.cancel()
        fixture.fail()
        await cancelled.value
        #expect(model.savedCollections.isLoaded && model.savedCollections.value?.isEmpty == true)
    }
}


extension HealthDataCollectionSettingsTests {
    private static func session() -> KeycloakSessionSnapshot {
        .init(generation: UUID(), issuer: URL(string: "https://identity.example/realm")!, subject: UUID().uuidString)
    }

    private static func collection(stopped: Bool) -> ParticipantCollectionState.Collection {
        .init(plan: .init(
            enrollmentId: UUID().uuidString,
            studyId: UUID().uuidString,
            title: .init([.enUS: "Saved Study"]),
            stateVersion: 1,
            asOf: Date(timeIntervalSince1970: 1),
            windows: []
        ), isStopped: stopped)
    }
}


extension HealthDataCollectionSettingsTests {
    @MainActor
    private final class Fixture {
        var session: KeycloakSessionSnapshot? = HealthDataCollectionSettingsTests.session()
        var actions: [HealthDataModel.Action] = []
        private var pending: [CheckedContinuation<[ParticipantCollectionState.Collection], any Error>] = []
        private let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(16))
        private var started = 0

        func model() -> HealthDataModel {
            HealthDataModel(transport: .init(
                session: { self.session },
                run: { action, _ in self.actions.append(action); return .ready },
                savedCollections: { _ in
                    try await withCheckedThrowingContinuation { continuation in
                        self.pending.append(continuation)
                        self.started += 1
                        self.events.continuation.yield(())
                    }
                }
            ))
        }

        func waitForCount(_ count: Int) async throws {
            if started >= count {
                return
            }
            for await _ in events.stream where started >= count {
                return
            }
            throw CancellationError()
        }

        func finish(_ value: [ParticipantCollectionState.Collection], at index: Int = 0) {
            pending.remove(at: index).resume(returning: value)
        }

        func fail() { pending.removeFirst().resume(throwing: URLError(.cannotOpenFile)) }

        func cancelAll() {
            pending.forEach { $0.resume(throwing: CancellationError()) }
            pending.removeAll()
            events.continuation.finish()
        }
    }
}
