//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Grove
import GroveAccount
import TroveAPIClient


private enum StorageError: LocalizedError {
    case mutationInProgress
    case unexpectedProfileResponse

    var errorDescription: String? {
        switch self {
        case .mutationInProgress:
            String(localized: "Another profile change is already in progress.")
        case .unexpectedProfileResponse:
            String(localized: "Could not load your profile.")
        }
    }
}


/// GroveAccount `AccountStorageProvider` that persists profile keys on the Trove REST API.
///
/// GroveAccount routes any `AccountKey` not handled by the registered identity provider's
/// `supportedKeys` through this provider. The provider maps `AccountDetails` to
/// `Trove.Profile` via ``ProfileMapping``.
@MainActor
public final class TroveAccountStorage: AccountStorageProvider, EnvironmentAccessible {
    struct Requests {
        var session: @MainActor () -> KeycloakSessionSnapshot?
        var fetch: @MainActor (KeycloakSessionSnapshot) async throws -> Trove.Profile?
        var save: @MainActor (KeycloakSessionSnapshot, Trove.ProfileInput, Bool) async throws -> Trove.Profile
        var publish: @MainActor (String, AccountDetails) -> Void
    }

    @Dependency(TroveAPIModule.self) private var apiModule
    @Dependency(ExternalAccountStorage.self) private var storage

    private let requests: Requests?
    private var session: KeycloakSessionSnapshot?
    private var generation = UUID()
    private var cache: AccountDetails?
    private var hasServerRecord = false
    private var fetchTask: Task<Void, Never>?
    private var mutationID: UUID?

    private var currentSession: KeycloakSessionSnapshot? {
        if let requests {
            return requests.session()
        }
        return apiModule.sessionSnapshot
    }

    public init() {
        requests = nil
    }

    init(requests: Requests) {
        self.requests = requests
    }

    public func load(_ accountId: String, _ keys: [any AccountKey.Type]) async -> AccountDetails? {
        guard let snapshot = try? prepare(accountId) else {
            return nil
        }
        if let cached = cache {
            return cached
        }
        if fetchTask == nil && mutationID == nil {
            let operationGeneration = generation
            fetchTask = Task {
                await fetchAndPublish(snapshot, generation: operationGeneration)
            }
        }
        return nil
    }

    public func store(_ accountId: String, _ modifications: AccountModifications) async throws {
        let snapshot = try prepare(accountId)
        guard mutationID == nil else {
            throw StorageError.mutationInProgress
        }
        // A prior read must not overwrite the result of this mutation.
        fetchTask?.cancel()
        fetchTask = nil
        generation = UUID()
        let operationGeneration = generation
        let operationID = UUID()
        var completed = false
        mutationID = operationID
        defer {
            if mutationID == operationID {
                mutationID = nil
                if !completed {
                    // An interrupted write may have committed remotely; reload before another edit.
                    cache = nil
                    hasServerRecord = false
                }
            }
        }

        if cache == nil {
            let profile: Trove.Profile?
            do {
                profile = try await fetch(snapshot)
            } catch {
                try validate(snapshot, generation: operationGeneration)
                throw TroveAccountError.profileFetchFailed(underlying: error)
            }
            try validate(snapshot, generation: operationGeneration)
            cache = profile.map(ProfileMapping.accountDetails) ?? AccountDetails()
            hasServerRecord = profile != nil
        }
        var details = cache ?? AccountDetails()
        details.add(contentsOf: modifications.modifiedDetails, merge: true)
        details.removeAll(modifications.removedAccountKeys)

        let input = ProfileMapping.profileInput(from: details)
        let updated: Trove.Profile
        do {
            updated = try await save(snapshot, input: input, existing: hasServerRecord)
        } catch {
            try validate(snapshot, generation: operationGeneration)
            throw TroveAccountError.profileUpdateFailed(underlying: error)
        }
        try validate(snapshot, generation: operationGeneration)
        let merged = ProfileMapping.accountDetails(from: updated)
        cache = merged
        hasServerRecord = true
        publish(accountId, merged)
        completed = true
    }

    public func disassociate(_ accountId: String) async {
        // Grove delivers this callback asynchronously with only a subject. An old logout
        // must not invalidate a newer authenticated session for the same participant.
        if session?.subject == accountId && session != currentSession {
            reset()
        }
    }

    public func delete(_ accountId: String) async throws {
        await disassociate(accountId)
        throw TroveAccountError.deletionUnsupported
    }

    private func prepare(_ accountId: String) throws -> KeycloakSessionSnapshot {
        let snapshot = currentSession
        if let expected = KeycloakSessionScope.expected, expected != snapshot {
            throw TroveAccountError.notSignedIn
        }
        if session != snapshot {
            reset()
            session = snapshot
        }
        guard let snapshot, snapshot.subject == accountId else {
            throw TroveAccountError.notSignedIn
        }
        return snapshot
    }

    private func reset() {
        generation = UUID()
        fetchTask?.cancel()
        fetchTask = nil
        mutationID = nil
        cache = nil
        hasServerRecord = false
    }

    private func validate(_ snapshot: KeycloakSessionSnapshot, generation: UUID) throws {
        guard currentSession == snapshot, session == snapshot else {
            throw TroveAccountError.notSignedIn
        }
        guard self.generation == generation else {
            throw CancellationError()
        }
        try Task.checkCancellation()
        if requests == nil {
            try apiModule.validateSession(snapshot)
        }
    }

    private func fetch(_ snapshot: KeycloakSessionSnapshot) async throws -> Trove.Profile? {
        if let requests {
            return try await requests.fetch(snapshot)
        }
        let output = try await apiModule.requireClient(for: snapshot).getParticipantProfile(.init())
        switch output {
        case .ok(let response):
            return try response.body.json
        case .notFound:
            return nil
        default:
            throw StorageError.unexpectedProfileResponse
        }
    }

    private func save(_ snapshot: KeycloakSessionSnapshot, input: Trove.ProfileInput, existing: Bool) async throws -> Trove.Profile {
        if let requests {
            return try await requests.save(snapshot, input, existing)
        }
        let client = try apiModule.requireClient(for: snapshot)
        if existing {
            return try await client.putParticipantProfile(.init(body: .json(input))).ok.body.json
        }
        return try await client.postParticipantProfile(.init(body: .json(input))).created.body.json
    }

    private func fetchAndPublish(_ snapshot: KeycloakSessionSnapshot, generation: UUID) async {
        defer {
            if self.generation == generation {
                fetchTask = nil
            }
        }
        do {
            let profile = try await fetch(snapshot)
            try validate(snapshot, generation: generation)
            let details = profile.map(ProfileMapping.accountDetails) ?? AccountDetails()
            cache = details
            hasServerRecord = profile != nil
            publish(snapshot.subject, details)
        } catch {
            // A failed or superseded request is not evidence of an empty profile.
        }
    }

    private func publish(_ accountId: String, _ details: AccountDetails) {
        if let requests {
            requests.publish(accountId, details)
        } else {
            storage.notifyAboutUpdatedDetails(for: accountId, details)
        }
    }
}
