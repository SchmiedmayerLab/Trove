//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import AppAuth
import Foundation
import Observation
import Testing
@testable import Trove


@MainActor
private final class SessionCompletionGate {
    private let waiting = AsyncStream<Void>.makeStream()
    private var completion: CheckedContinuation<String, any Error>?
    private var result: Result<String, any Error>?

    func suspend() async throws -> String {
        if let result {
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            waiting.continuation.yield(())
            waiting.continuation.finish()
        }
    }

    func waitUntilSuspended() async throws {
        for await _ in waiting.stream { break }
        try Task.checkCancellation()
    }

    func finish(_ result: Result<String, any Error>) {
        guard self.result == nil else {
            return
        }
        self.result = result
        completion?.resume(with: result)
        completion = nil
        waiting.continuation.finish()
    }
}


@MainActor
@Suite(.timeLimit(.minutes(1)))
struct KeycloakSessionLifecycleTests {
    private enum RefreshError: Error { case failed }

    private static func install(_ subject: String, in lifecycle: KeycloakSessionLifecycle) throws -> KeycloakSessionSnapshot {
        let issuer = try #require(URL(string: "https://identity.example.test/realms/trove"))
        try lifecycle.install(subject: subject, issuer: issuer, for: lifecycle.generation)
        return try #require(lifecycle.snapshot)
    }

    @Test(arguments: ["logout", "different-account", "same-account-new-login"])
    func lateSuccessCannotReachCredentialOrProfileCommit(change: String) async throws {
        let lifecycle = KeycloakSessionLifecycle()
        let original = try Self.install("participant-a", in: lifecycle)
        let gate = SessionCompletionGate()
        var committed: String?
        let pending = Task {
            let result = try await lifecycle.perform(for: original.generation) { try await gate.suspend() }
            // This is the same commit boundary used by token persistence and profile publication.
            committed = result
        }
        defer {
            pending.cancel()
            gate.finish(.failure(CancellationError()))
        }
        try await gate.waitUntilSuspended()
        lifecycle.invalidate()
        if change != "logout" {
            _ = try Self.install(change == "different-account" ? "participant-b" : "participant-a", in: lifecycle)
        }
        let current = lifecycle.snapshot
        gate.finish(.success("obsolete-token-or-profile"))
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(committed == nil)
        #expect(lifecycle.snapshot == current)
    }

    @Test
    func lateRefreshFailureCannotClearNewAccount() async throws {
        let lifecycle = KeycloakSessionLifecycle()
        let original = try Self.install("participant-a", in: lifecycle)
        let gate = SessionCompletionGate()
        var cleared = false
        let pending = Task {
            do {
                _ = try await lifecycle.perform(for: original.generation) { try await gate.suspend() }
            } catch {
                if lifecycle.generation == original.generation {
                    cleared = true
                    lifecycle.invalidate()
                }
                throw error
            }
        }
        defer {
            pending.cancel()
            gate.finish(.failure(CancellationError()))
        }
        try await gate.waitUntilSuspended()
        lifecycle.invalidate()
        let current = try Self.install("participant-b", in: lifecycle)
        gate.finish(.failure(RefreshError.failed))
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(!cleared)
        #expect(lifecycle.snapshot == current)
    }

    @Test
    func cancelledOperationCannotCommitItsLateSuccess() async throws {
        let lifecycle = KeycloakSessionLifecycle()
        let snapshot = try Self.install("participant-a", in: lifecycle)
        let gate = SessionCompletionGate()
        var committed = false
        let pending = Task {
            _ = try await lifecycle.perform(for: snapshot.generation) { try await gate.suspend() }
            committed = true
        }
        defer {
            pending.cancel()
            gate.finish(.failure(CancellationError()))
        }
        try await gate.waitUntilSuspended()
        pending.cancel()
        gate.finish(.success("late-token"))
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(!committed)
        #expect(lifecycle.snapshot == snapshot)
    }

    @Test
    func currentSessionRefreshKeepsRequestIdentity() async throws {
        let lifecycle = KeycloakSessionLifecycle()
        let snapshot = try Self.install("participant-a", in: lifecycle)
        let gate = SessionCompletionGate()
        let pending = Task { try await lifecycle.perform(for: snapshot.generation) { try await gate.suspend() } }
        defer {
            pending.cancel()
            gate.finish(.failure(CancellationError()))
        }
        try await gate.waitUntilSuspended()
        gate.finish(.success("refreshed-token"))
        let token = try await pending.value
        #expect(token == "refreshed-token")
        try lifecycle.validate(snapshot)
        #expect(lifecycle.snapshot == snapshot)
    }

    @Test
    func staleAuthorizationCannotInstallAfterLogout() async throws {
        let lifecycle = KeycloakSessionLifecycle()
        let authorizationGeneration = lifecycle.generation
        let gate = SessionCompletionGate()
        let issuer = try #require(URL(string: "https://identity.example.test/realms/trove"))
        let pending = Task {
            let subject = try await lifecycle.perform(for: authorizationGeneration) { try await gate.suspend() }
            try lifecycle.install(subject: subject, issuer: issuer, for: authorizationGeneration)
        }
        defer {
            pending.cancel()
            gate.finish(.failure(CancellationError()))
        }
        try await gate.waitUntilSuspended()
        lifecycle.invalidate()
        gate.finish(.success("participant-a"))
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(lifecycle.snapshot == nil)
    }

    @Test
    func providerErrorDescriptionNeverReachesAccountButton() {
        let sentinel = "private-server-response-and-token"
        let providerError = NSError(domain: OIDOAuthAuthorizationErrorDomain, code: -1, userInfo: [
            NSLocalizedDescriptionKey: sentinel,
            NSUnderlyingErrorKey: NSError(domain: sentinel, code: 1)
        ])
        let presented = KeycloakAccountService.sanitizedAuthorizationError(providerError)
        #expect(presented is KeycloakAccountError)
        #expect(!presented.localizedDescription.contains(sentinel))
        #expect(!String(reflecting: presented).contains(sentinel))
    }

    @Test(arguments: [OIDErrorCode.userCanceledAuthorizationFlow.rawValue, OIDErrorCode.programCanceledAuthorizationFlow.rawValue])
    func typedProviderCancellationIsPreserved(code: Int) {
        let cancellation = NSError(domain: OIDGeneralErrorDomain, code: code)
        #expect(KeycloakAccountService.sanitizedAuthorizationError(cancellation) is CancellationError)
        let otherDomain = NSError(domain: "unrelated-provider", code: code)
        #expect(KeycloakAccountService.sanitizedAuthorizationError(otherDomain) is KeycloakAccountError)
    }

    @Test
    func knownLocalFailureAndTaskCancellationArePreserved() {
        let local = KeycloakAccountService.sanitizedAuthorizationError(KeycloakAccountError.notSignedIn)
        #expect(local.localizedDescription == KeycloakAccountError.notSignedIn.localizedDescription)
        #expect(KeycloakAccountService.sanitizedAuthorizationError(CancellationError()) is CancellationError)
    }
}
