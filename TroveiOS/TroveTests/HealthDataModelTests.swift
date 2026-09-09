//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import Trove
import TroveAPIClient


@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HealthDataModelTests {
    @Test
    func repeatedActionsCannotStartConcurrentCollection() async throws {
        let fixture = try Fixture()
        let model = fixture.model()
        let first = Task { await model.run(.sync) }
        await fixture.waitForStart()
        #expect(model.isBusy)
        await model.run(.setUp)
        #expect(fixture.completions.count == 1)
        fixture.finish(.syncFinished, at: 0)
        await first.value
        #expect(!model.isBusy && model.status == .syncFinished)
    }

    @Test
    func oldSessionCannotPublishOrUnlockANewSessionOperation() async throws {
        let fixture = try Fixture()
        let model = fixture.model()
        let first = Task { await model.run(.sync) }
        await fixture.waitForStart()
        fixture.session = try Fixture.session()
        #expect(model.status == .signedOut && !model.isBusy)
        let second = await fixture.start { await model.run(.refresh) }
        #expect(fixture.completions.count == 1, "The old journal must close before another session opens it.")
        fixture.finish(.syncFinished, at: 0)
        await first.value
        await fixture.waitForStart()
        #expect(fixture.cancellations == [true])
        #expect(model.isBusy && model.status != .syncFinished)
        fixture.finish(.ready, at: 1)
        await second.value
        #expect(!model.isBusy && model.status == .ready)
    }

    @Test
    func cancelledOperationPreservesTheLastVisibleState() async throws {
        let fixture = try Fixture()
        let model = fixture.model()
        let first = Task { await model.run(.refresh) }
        await fixture.waitForStart()
        fixture.finish(.ready, at: 0)
        await first.value
        let sync = Task { await model.run(.sync) }
        await fixture.waitForStart()
        sync.cancel()
        fixture.finish(.syncFinished, at: 1)
        await sync.value
        #expect(!model.isBusy && model.status == .ready)
    }

    @Test
    func observerWakeWaitsForItsOwnCaptureRatherThanJoiningAnOlderQuery() async throws {
        let fixture = try Fixture()
        let captured = try #require(fixture.session)
        let model = fixture.model()
        let first = Task { await model.run(.sync) }
        await fixture.waitForStart()
        let update = await fixture.start { await model.receiveHealthUpdate(for: captured, context: .foreground) }
        #expect(fixture.actions == [.sync])
        fixture.finish(.syncFinished, at: 0)
        await first.value
        await fixture.waitForStart()
        #expect(fixture.actions == [.sync, .capture])
        #expect(fixture.cancellations == [false])
        fixture.finish(.waiting, at: 1)
        await update.value
        #expect(!model.isBusy && model.status == .waiting)
    }

    @Test
    func cancelledObserverWaitDoesNotCancelAnotherOwnersOperation() async throws {
        let fixture = try Fixture()
        let captured = try #require(fixture.session)
        let model = fixture.model()
        let first = Task { await model.run(.sync) }
        await fixture.waitForStart()
        let update = await fixture.start { await model.receiveHealthUpdate(for: captured, context: .foreground) }
        update.cancel()
        await update.value
        #expect(fixture.actions == [.sync] && model.isBusy)
        fixture.finish(.syncFinished, at: 0)
        await first.value
        #expect(fixture.cancellations == [false])
    }

    @Test
    func backgroundWakeCancelsUploadThenWaitsForCleanupBeforeCapturing() async throws {
        let fixture = try Fixture()
        let captured = try #require(fixture.session)
        let model = fixture.model()
        let first = Task { await model.run(.sync) }
        await fixture.waitForStart()
        let update = await fixture.start { await model.receiveHealthUpdate(for: captured, context: .background) }
        #expect(fixture.actions == [.sync])
        fixture.finish(.syncFinished, at: 0)
        await first.value
        await fixture.waitForStart()
        #expect(fixture.cancellations == [true])
        #expect(fixture.actions == [.sync, .capture])
        #expect(model.status != .syncFinished)
        fixture.finish(.waiting, at: 1)
        await update.value
        #expect(!model.isBusy && model.status == .waiting)
    }

    @Test
    func changingAccountReleasesOldObserverWaitWithoutRedirectingItsQuery() async throws {
        let fixture = try Fixture()
        let captured = try #require(fixture.session)
        let model = fixture.model()
        let first = Task { await model.run(.sync) }
        await fixture.waitForStart()
        let update = await fixture.start { await model.receiveHealthUpdate(for: captured, context: .foreground) }
        fixture.session = try Fixture.session()
        model.invalidateSession()
        await update.value
        #expect(fixture.actions == [.sync])
        #expect(model.status == .signedOut && !model.isBusy)
        fixture.finish(.syncFinished, at: 0)
        await first.value
        #expect(fixture.cancellations == [true])
        #expect(model.status == .signedOut)
    }

    @Test
    func staleObserverCallbackCannotStartWorkForTheReplacementAccount() async throws {
        let fixture = try Fixture()
        let captured = try #require(fixture.session)
        let model = fixture.model()
        fixture.session = try Fixture.session()
        await model.receiveHealthUpdate(for: captured, context: .background)
        #expect(fixture.actions.isEmpty && model.status == .signedOut)
    }

    @Test
    func expiredCaptureBudgetCancelsButStillWaitsForJournalCleanup() async throws {
        let fixture = try Fixture()
        let captured = try #require(fixture.session)
        let deadline = AsyncStream<Void>.makeStream()
        let model = fixture.model { for await _ in deadline.stream { break } }
        let update = Task { await model.receiveHealthUpdate(for: captured, context: .background) }
        await fixture.waitForStart()
        deadline.continuation.finish()
        await fixture.waitForCancellation()
        #expect(model.isBusy)
        await model.run(.refresh)
        #expect(fixture.actions == [.capture], "The cancelled journal still owns the operation until it closes.")
        fixture.finish(.syncFinished, at: 0)
        await update.value
        #expect(!model.isBusy && model.status != .syncFinished)
        #expect(fixture.cancellations == [true])
    }

    @Test
    func alreadyCancelledBackgroundWakeDoesNotCancelAnActiveUpload() async throws {
        let fixture = try Fixture()
        let captured = try #require(fixture.session)
        let model = fixture.model()
        let upload = Task { await model.run(.sync) }
        await fixture.waitForStart()
        let update = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.receiveHealthUpdate(for: captured, context: .background)
        }
        await update.value
        fixture.finish(.syncFinished, at: 0)
        await upload.value
        #expect(fixture.actions == [.sync] && fixture.cancellations == [false])
    }

    @Test
    func knownFailuresHaveSafeLocalizableStates() {
        #expect(HealthDataStatus(error: EventDeliveryJournal.JournalError.corruptJournal) == .blocked)
        #expect(HealthDataStatus(error: EventDeliveryJournal.JournalError.sourceRevoked) == .revoked)
        #expect(HealthDataStatus(error: ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized) == .notAuthorized)
        #expect(HealthDataStatus(error: URLError(.notConnectedToInternet)) == .unavailable)
    }
}


extension HealthDataModelTests {
    @MainActor
    private final class Fixture {
        var session: KeycloakSessionSnapshot?
        var completions: [CheckedContinuation<HealthDataStatus, Never>?] = []
        var actions: [HealthDataModel.Action] = []
        var cancellations: [Bool] = []
        private let starts = AsyncStream<Void>.makeStream()
        private let cancellationRequests = AsyncStream<Void>.makeStream()

        init() throws { session = try Self.session() }

        static func session() throws -> KeycloakSessionSnapshot {
            .init(generation: UUID(), issuer: try #require(URL(string: "https://identity.example/realm")), subject: "participant")
        }

        func model(
            waitForDeadline: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(20)) }
        ) -> HealthDataModel {
            HealthDataModel(transport: .init(session: { self.session }, run: { action, _ in
                self.actions.append(action)
                let cancelled = self.cancellationRequests.continuation
                let result = await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        self.completions.append(continuation)
                        self.starts.continuation.yield(())
                    }
                } onCancel: {
                    cancelled.yield(())
                }
                self.cancellations.append(Task.isCancelled)
                return result
            }), waitForCaptureDeadline: waitForDeadline)
        }

        func start(_ operation: @escaping @MainActor () async -> Void) async -> Task<Void, Never> {
            let entered = AsyncStream<Void>.makeStream()
            let task = Task {
                entered.continuation.yield(())
                await operation()
                entered.continuation.finish()
            }
            for await _ in entered.stream { break }
            return task
        }

        func waitForStart() async {
            for await _ in starts.stream { break }
        }

        func waitForCancellation() async {
            for await _ in cancellationRequests.stream { break }
        }

        func finish(_ value: HealthDataStatus, at index: Int) {
            completions[index]?.resume(returning: value)
            completions[index] = nil
        }
    }
}
