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


@MainActor
@Suite(.timeLimit(.minutes(1)))
struct EnrollmentModelTests {
    @Test(arguments: [false, true])
    func latestRefreshWinsEvenWhenEarlierRequestFails(earlierFails: Bool) async throws {
        let fixture = Fixture()
        defer { fixture.cancelAll() }
        let model = fixture.model()
        let first = Task { await model.refresh() }
        try await fixture.lists.waitForCount(1)
        let second = Task { await model.refresh() }
        try await fixture.lists.waitForCount(2)
        fixture.lists.finish([Self.enrollment(version: 2)], at: 1)
        await second.value
        if earlierFails {
            fixture.lists.fail()
        } else {
            fixture.lists.finish([Self.enrollment(version: 1)])
        }
        await first.value
        #expect(model.state.value?.first?.stateVersion == 2)
        #expect(model.state.isLoaded)
    }

    @Test
    func refreshCannotReplaceWithdrawalAndRefreshDuringMutationIsSkipped() async throws {
        let fixture = Fixture()
        defer { fixture.cancelAll() }
        let model = fixture.model()
        await fixture.load(model, with: [Self.enrollment()])
        let refresh = Task { await model.refresh() }
        try await fixture.lists.waitForCount(2)
        let withdrawal = Task { try await model.withdraw(enrollmentId: "enrollment") }
        try await fixture.withdrawals.waitForCount(1)
        await model.refresh()
        #expect(fixture.lists.started == 2)
        #expect(model.isMutating)
        let withdrawn = Self.enrollment(version: 2, withdrawn: true)
        fixture.withdrawals.finish(withdrawn)
        try await withdrawal.value
        fixture.lists.finish([Self.enrollment()])
        await refresh.value
        #expect(model.state.value == [withdrawn])
        #expect(model.activeEnrollment(forStudy: "study") == nil)
        #expect(!model.isMutating)
    }

    @Test(arguments: ["participant", "other"])
    func sessionChangeHidesStoredValuesBeforeInvalidationCallback(nextSubject: String) async throws {
        let fixture = Fixture()
        defer { fixture.cancelAll() }
        let model = fixture.model()
        await fixture.load(model, with: [Self.enrollment()])
        fixture.session = nil
        #expect(model.state.value == nil)
        #expect(model.latestEnrollment(forStudy: "study") == nil)
        fixture.session = Self.session(subject: nextSubject)
        #expect(model.state.value == nil)
        let refresh = Task { await model.refresh() }
        try await fixture.lists.waitForCount(2)
        model.synchronizeSession()
        fixture.lists.finish([])
        await refresh.value
        #expect(model.state.isLoaded)
        #expect(model.state.value?.isEmpty == true)
    }

    @Test(arguments: [false, true])
    func oldMutationCannotPublishOrUnlockNewAccountMutation(oldFails: Bool) async throws {
        let fixture = Fixture()
        defer { fixture.cancelAll() }
        let model = fixture.model()
        await fixture.load(model, with: [])
        let old = Task { try await model.enroll(studyId: "study") }
        try await fixture.enrollments.waitForCount(1)
        fixture.session = Self.session(subject: "other")
        #expect(!model.isMutating)
        #expect(model.state.value == nil)
        await fixture.load(model, with: [])
        let current = Task { try await model.enroll(studyId: "other-study") }
        try await fixture.enrollments.waitForCount(2)
        if oldFails {
            fixture.enrollments.fail()
        } else {
            fixture.enrollments.finish(Self.enrollment())
        }
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(model.isMutating)
        #expect(model.state.value?.isEmpty == true)
        let accepted = Self.enrollment(participant: "other", study: "other-study")
        fixture.enrollments.finish(accepted)
        try await current.value
        #expect(model.state.value == [accepted])
        #expect(!model.isMutating)
        #expect(fixture.requestedSessions.map(\.subject) == ["participant", "participant", "other", "other"])
    }

    @Test
    func obsoleteCancelledRefreshCannotResetNewLoadingState() async throws {
        let fixture = Fixture()
        defer { fixture.cancelAll() }
        let model = fixture.model()
        await fixture.load(model, with: [Self.enrollment()])
        let old = Task { await model.refresh() }
        try await fixture.lists.waitForCount(2)
        let current = Task { await model.refresh() }
        try await fixture.lists.waitForCount(3)
        old.cancel()
        fixture.lists.fail()
        await old.value
        #expect(model.state.isLoading)
        fixture.lists.finish([Self.enrollment(version: 2)])
        await current.value
        #expect(model.state.value?.first?.stateVersion == 2)
    }

    @Test
    func cancelledCurrentRefreshRestoresLastResolvedValue() async throws {
        let fixture = Fixture()
        defer { fixture.cancelAll() }
        let model = fixture.model()
        await fixture.load(model, with: [Self.enrollment()])
        let refresh = Task { await model.refresh() }
        try await fixture.lists.waitForCount(2)
        refresh.cancel()
        fixture.lists.fail()
        await refresh.value
        #expect(model.state.isLoaded)
        #expect(model.state.value == [Self.enrollment()])
    }

    @Test
    func loggedOutRefreshAndUnavailableMutationDoNotSendRequests() async throws {
        let fixture = Fixture()
        fixture.session = nil
        defer { fixture.cancelAll() }
        let model = fixture.model()
        await model.refresh()
        await #expect(throws: EnrollmentModelError.self) { try await model.enroll(studyId: "study") }
        #expect(fixture.requestedSessions.isEmpty)
        #expect(model.state.value == nil)
    }

    @Test
    func receivedMutationResultRemainsAuthoritativeAfterViewTaskCancellation() async throws {
        let fixture = Fixture()
        defer { fixture.cancelAll() }
        let model = fixture.model()
        await fixture.load(model, with: [Self.enrollment()])
        let withdrawal = Task { try await model.withdraw(enrollmentId: "enrollment") }
        try await fixture.withdrawals.waitForCount(1)
        withdrawal.cancel()
        let accepted = Self.enrollment(version: 2, withdrawn: true)
        fixture.withdrawals.finish(accepted)
        try await withdrawal.value
        #expect(model.state.value == [accepted])
        #expect(!model.isMutating)
    }
}


extension EnrollmentModelTests {
    private static func session(subject: String = "participant") -> KeycloakSessionSnapshot {
        KeycloakSessionSnapshot(generation: UUID(), issuer: URL(string: "https://identity.example/realm")!, subject: subject)
    }

    private static func enrollment(
        version: Int64 = 1, participant: String = "participant", study: String = "study", withdrawn: Bool = false
    ) -> Trove.Enrollment {
        .init(
            id: "enrollment",
            studyId: study,
            participantId: participant,
            currentRevision: 1,
            stateVersion: version,
            enrolledAt: Date(timeIntervalSince1970: 1),
            withdrawnAt: withdrawn ? Date(timeIntervalSince1970: 2) : nil
        )
    }
}


extension EnrollmentModelTests {
    @MainActor
    private final class Fixture {
        var session: KeycloakSessionSnapshot? = EnrollmentModelTests.session()
        let lists = Replies<[Trove.Enrollment]>()
        let enrollments = Replies<Trove.Enrollment>()
        let withdrawals = Replies<Trove.Enrollment>()
        var requestedSessions: [KeycloakSessionSnapshot] = []

        func model() -> EnrollmentModel {
            EnrollmentModel(transport: .init(
                session: { self.session },
                list: { session in
                    self.requestedSessions.append(session)
                    return try await self.lists.request()
                },
                enroll: { session, _, _ in
                    self.requestedSessions.append(session)
                    return try await self.enrollments.request()
                },
                withdraw: { session, _ in
                    self.requestedSessions.append(session)
                    return try await self.withdrawals.request()
                }
            ))
        }

        func load(_ model: EnrollmentModel, with values: [Trove.Enrollment]) async {
            let count = lists.started + 1
            let load = Task { await model.refresh() }
            do {
                try await lists.waitForCount(count)
                lists.finish(values)
            } catch {
                Issue.record(error)
                cancelAll()
            }
            await load.value
        }

        func cancelAll() {
            lists.cancelAll()
            enrollments.cancelAll()
            withdrawals.cancelAll()
        }
    }

    /// One response per explicitly observed request, without network, sleep or global fixtures.
    @MainActor
    private final class Replies<Value: Sendable> {
        private var pending: [CheckedContinuation<Value, any Error>] = []
        private let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(16))
        private(set) var started = 0

        func request() async throws -> Value {
            try await withCheckedThrowingContinuation { continuation in
                pending.append(continuation)
                started += 1
                events.continuation.yield(())
            }
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

        func finish(_ value: Value, at index: Int = 0) {
            pending.remove(at: index).resume(returning: value)
        }

        func fail() {
            pending.removeFirst().resume(throwing: URLError(.networkConnectionLost))
        }

        func cancelAll() {
            pending.forEach { $0.resume(throwing: CancellationError()) }
            pending.removeAll()
            events.continuation.finish()
        }
    }
}
