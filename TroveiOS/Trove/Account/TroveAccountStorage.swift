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


/// GroveAccount `AccountStorageProvider` that persists profile keys on the Trove REST API.
///
/// GroveAccount routes any `AccountKey` not handled by the registered identity provider's
/// `supportedKeys` through this provider. The provider maps `AccountDetails` to
/// `Trove.Profile` via ``ProfileMapping``.
public actor TroveAccountStorage: AccountStorageProvider, EnvironmentAccessible {
    @Dependency(TroveAPIModule.self) private var apiModule
    @Dependency(ExternalAccountStorage.self) private var storage

    private var cache: [String: AccountDetails] = [:]
    private var hasServerRecord: Set<String> = []

    public init() {}

    public func load(_ accountId: String, _ keys: [any AccountKey.Type]) async -> AccountDetails? {
        if let cached = cache[accountId] {
            return cached
        }
        Task { await fetchAndPublish(accountId) }
        return nil
    }

    public func store(_ accountId: String, _ modifications: AccountModifications) async throws {
        var details = cache[accountId] ?? AccountDetails()
        details.add(contentsOf: modifications.modifiedDetails, merge: true)
        details.removeAll(modifications.removedAccountKeys)

        guard let client = apiModule.client else { throw TroveAccountError.clientUnavailable }
        let input = ProfileMapping.profileInput(from: details)
        let updated: Trove.Profile
        do {
            if hasServerRecord.contains(accountId) {
                updated = try await client.putParticipantProfile(.init(body: .json(input))).ok.body.json
            } else {
                updated = try await client.postParticipantProfile(.init(body: .json(input))).created.body.json
                hasServerRecord.insert(accountId)
            }
        } catch {
            throw TroveAccountError.profileUpdateFailed(underlying: error)
        }
        let merged = ProfileMapping.accountDetails(from: updated)
        cache[accountId] = merged
        storage.notifyAboutUpdatedDetails(for: accountId, merged)
    }

    public func disassociate(_ accountId: String) async {
        cache.removeValue(forKey: accountId)
        hasServerRecord.remove(accountId)
    }

    public func delete(_ accountId: String) async throws {
        await disassociate(accountId)
        throw TroveAccountError.deletionUnsupported
    }

    private func fetchAndPublish(_ accountId: String) async {
        guard let client = apiModule.client else {
            cache[accountId] = AccountDetails()
            storage.notifyAboutUpdatedDetails(for: accountId, AccountDetails())
            return
        }
        guard let output = try? await client.getParticipantProfile(.init()),
              case .ok(let ok) = output,
              let profile = try? ok.body.json else {
            cache[accountId] = AccountDetails()
            storage.notifyAboutUpdatedDetails(for: accountId, AccountDetails())
            return
        }
        hasServerRecord.insert(accountId)
        let details = ProfileMapping.accountDetails(from: profile)
        cache[accountId] = details
        storage.notifyAboutUpdatedDetails(for: accountId, details)
    }
}
