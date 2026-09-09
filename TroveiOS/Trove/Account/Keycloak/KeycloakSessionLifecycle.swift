//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Observation


struct KeycloakSessionSnapshot: Hashable, Sendable {
    let generation: UUID
    let issuer: URL
    let subject: String
}


/// Preserves the initiating session across Grove's subject-only storage interface.
/// This value can reject a request; it must never select the account or credentials.
enum KeycloakSessionScope {
    @TaskLocal static var expected: KeycloakSessionSnapshot?
}


/// Rejects late authentication completions without applying them to a newer session.
@MainActor
@Observable
final class KeycloakSessionLifecycle {
    private(set) var generation = UUID()
    private(set) var snapshot: KeycloakSessionSnapshot?

    @discardableResult
    func invalidate() -> UUID {
        generation = UUID()
        snapshot = nil
        return generation
    }

    func requireGeneration(_ expected: UUID) throws {
        guard generation == expected else { throw CancellationError() }
    }

    func validate(_ expected: KeycloakSessionSnapshot) throws {
        guard snapshot == expected else { throw CancellationError() }
    }

    func install(subject: String, issuer: URL, for expected: UUID) throws {
        try requireGeneration(expected)
        guard !subject.isEmpty else { throw KeycloakAccountError.missingIDToken }
        snapshot = .init(generation: expected, issuer: issuer, subject: subject)
    }

    func perform<Value>(for expected: UUID, _ operation: @MainActor () async throws -> Value) async throws -> Value {
        try requireGeneration(expected)
        try Task.checkCancellation()
        do {
            let value = try await operation()
            try requireGeneration(expected)
            try Task.checkCancellation()
            return value
        } catch {
            // A stale failure must not clear credentials or publish errors for a new account.
            try requireGeneration(expected)
            try Task.checkCancellation()
            throw error
        }
    }
}
