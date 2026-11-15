//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// One bounded scheduling step, independently callable with synthetic transports and an explicit clock.
struct ProviderWorkerService: Sendable {
    let store: ProviderWorkerStore
    let workers: [ConnectedProvider: ProviderIngestionService]
    var retirement: ProviderCredentialRetirement?

    @discardableResult
    func tick(now: Date = Date()) async throws -> Bool {
        try await retirement?.run(now: now)
        for candidate in try await store.candidates(now: now) {
            try Task.checkCancellation()
            guard let worker = workers[candidate.registration.provider] else { continue }
            let tokens = candidate.registration.sourceTokens.intersection(worker.client.qualifiedSourceTokens)
            guard !tokens.isEmpty, let token = try await store.claim(candidate, tokens: tokens, now: now) else { continue }
            let outcome: ProviderWorkerStore.Outcome
            do {
                switch try await worker.collect(connectionID: candidate.connection.id, sourceToken: token, now: now) {
                case .accepted: outcome = .accepted
                case .noCurrentDemand: outcome = .idle
                case .deferred: outcome = .deferred
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                outcome = .failed(.classify(error))
            }
            try await store.finished(candidate, sourceToken: token, outcome: outcome, now: now)
            return true
        }
        return false
    }
}
