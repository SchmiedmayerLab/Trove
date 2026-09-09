//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Testing
@testable import Trove


@MainActor
@Suite(.timeLimit(.minutes(1)))
struct KeycloakTokenRequestTests {
    private enum Failure: Error { case expected }

    @Test
    func preservesSynchronousCompletion() async throws {
        let token = try await KeycloakTokenRequest.value { $0(.success("current-token")) }
        #expect(token == "current-token")
    }

    @Test
    func preservesSDKFailure() async {
        await #expect(throws: Failure.self) {
            try await KeycloakTokenRequest.value { $0(.failure(Failure.expected)) }
        }
    }

    @Test
    func alreadyCancelledCallerDoesNotStartSDKWork() async {
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await KeycloakTokenRequest.value { _ in Issue.record("Cancelled request started SDK work.") }
        }
        await #expect(throws: CancellationError.self) { try await request.value }
    }
    @Test(arguments: [false, true])
    func cancellationReturnsBeforeALateSDKCallback(failure: Bool) async throws {
        let fixture = Fixture()
        let request = Task { try await KeycloakTokenRequest.value(start: fixture.start) }
        await fixture.waitForStart()
        request.cancel()
        // Must finish before the callback: checking cancellation only after a reply would hang here.
        await #expect(throws: CancellationError.self) { try await request.value }
        let complete = try #require(fixture.completion)
        complete(failure ? .failure(Failure.expected) : .success("late-token"))
    }

    @Test
    func cancellingOneWaiterDoesNotCancelAnotherSDKCaller() async throws {
        let first = Fixture()
        let second = Fixture()
        let cancelled = Task { try await KeycloakTokenRequest.value(start: first.start) }
        let retained = Task { try await KeycloakTokenRequest.value(start: second.start) }
        await first.waitForStart()
        await second.waitForStart()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let finishFirst = try #require(first.completion)
        let finishSecond = try #require(second.completion)
        finishFirst(.success("shared-refresh-token"))
        finishSecond(.success("shared-refresh-token"))
        #expect(try await retained.value == "shared-refresh-token")
    }

    @Test
    func cancellationAfterSynchronousResponseCannotPublishTheToken() async {
        let request = Task {
            try await KeycloakTokenRequest.value { complete in
                complete(.success("already-buffered-token"))
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await request.value }
    }
}


extension KeycloakTokenRequestTests {
    @MainActor
    private final class Fixture {
        var completion: KeycloakTokenRequest.Completion?
        private let started = AsyncStream<Void>.makeStream()

        func start(_ completion: @escaping KeycloakTokenRequest.Completion) {
            self.completion = completion
            started.continuation.yield(())
            started.continuation.finish()
        }

        func waitForStart() async { for await _ in started.stream { break } }
    }
}
