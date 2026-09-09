//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveAccount
import Testing
@testable import Trove
import TroveAPIClient


@MainActor
private final class ProfileRequestGate {
    private let started = AsyncStream<Void>.makeStream()
    private let released = AsyncStream<Void>.makeStream()

    func pause() async throws {
        started.continuation.yield(())
        started.continuation.finish()
        for await _ in released.stream { break }
        try Task.checkCancellation()
    }

    func waitUntilStarted() async throws {
        for await _ in started.stream { break }
        try Task.checkCancellation()
    }

    func release() {
        released.continuation.finish()
    }
}


@MainActor
private final class ProfileRequests {
    var snapshot: KeycloakSessionSnapshot?
    var profile: Trove.Profile?
    var fetchGate: ProfileRequestGate?
    var saveGate: ProfileRequestGate?
    var fetchError: (any Error)?
    var saveError: (any Error)?
    var fetchCount = 0
    var saveCount = 0
    var savedExisting: [Bool] = []
    var publications: [AccountDetails] = []

    init() throws {
        snapshot = KeycloakSessionSnapshot(
            generation: UUID(),
            issuer: try #require(URL(string: "https://identity.example.test/realms/test")),
            subject: "alice"
        )
        profile = Trove.Profile(
            id: "alice",
            firstName: "Alice",
            lastName: "Participant",
            email: "alice@example.test",
            gender: .preferNotToState,
            dateOfBirth: "1990-01-01",
            region: "US",
            language: "en-US",
            phoneNumber: ""
        )
    }

    func makeStorage() -> TroveAccountStorage {
        TroveAccountStorage(requests: .init(
            session: { self.snapshot },
            fetch: { _ in
                self.fetchCount += 1
                try await self.fetchGate?.pause()
                if let error = self.fetchError {
                    throw error
                }
                return self.profile
            },
            save: { _, input, existing in
                self.saveCount += 1
                self.savedExisting.append(existing)
                let response = try #require(self.profile)
                try await self.saveGate?.pause()
                var updated = response
                updated.firstName = input.firstName
                updated.region = input.region
                self.profile = updated
                if let error = self.saveError {
                    throw error
                }
                return updated
            },
            publish: { _, details in self.publications.append(details) }
        ))
    }
}


@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TroveAccountStorageTests {
    @Test
    func mismatchedAccountCannotReadOrWriteProfile() async throws {
        let requests = try ProfileRequests()
        let storage = requests.makeStorage()
        #expect(await storage.load("bob", []) == nil)
        await #expect(throws: TroveAccountError.self) {
            try await storage.store("bob", AccountDetails())
        }
        #expect(requests.fetchCount == 0)
        #expect(requests.saveCount == 0)
        #expect(requests.publications.isEmpty)
    }

    @Test(arguments: [false, true])
    func lateSaveCannotPublishAfterSessionInvalidation(disassociate: Bool) async throws {
        let requests = try ProfileRequests()
        let gate = ProfileRequestGate()
        requests.saveGate = gate
        let storage = requests.makeStorage()
        let operation = Task { try await storage.store("alice", AccountDetails()) }
        defer {
            operation.cancel()
            gate.release()
        }
        try await gate.waitUntilStarted()
        requests.snapshot = nil
        if disassociate {
            await storage.disassociate("alice")
        }
        gate.release()
        await #expect(throws: TroveAccountError.self) { try await operation.value }
        #expect(requests.publications.isEmpty)
        #expect(await storage.load("alice", []) == nil)
        #expect(requests.fetchCount == 1)
    }

    @Test
    func forwardedOldSessionCannotStartProfileRequestAfterSameSubjectRelogin() async throws {
        let requests = try ProfileRequests()
        let storage = requests.makeStorage()
        let gate = ProfileRequestGate()
        let old = try #require(requests.snapshot)
        let operation = Task {
            try await KeycloakSessionScope.$expected.withValue(old) {
                try await gate.pause()
                try await storage.store("alice", AccountDetails())
            }
        }
        defer {
            operation.cancel()
            gate.release()
        }
        try await gate.waitUntilStarted()
        requests.snapshot = .init(generation: UUID(), issuer: old.issuer, subject: old.subject)
        gate.release()
        await #expect(throws: TroveAccountError.self) { try await operation.value }
        #expect(requests.fetchCount == 0)
        #expect(requests.saveCount == 0)
        #expect(requests.publications.isEmpty)
    }

    @Test
    func lateInitialReadCannotStartWriteAfterSignOut() async throws {
        let requests = try ProfileRequests()
        let gate = ProfileRequestGate()
        requests.fetchGate = gate
        let storage = requests.makeStorage()
        let operation = Task { try await storage.store("alice", AccountDetails()) }
        defer {
            operation.cancel()
            gate.release()
        }
        try await gate.waitUntilStarted()
        requests.snapshot = nil
        gate.release()
        await #expect(throws: TroveAccountError.self) { try await operation.value }
        #expect(requests.saveCount == 0)
        #expect(requests.publications.isEmpty)
        #expect(await storage.load("alice", []) == nil)
    }

    @Test
    func newSessionForSameSubjectCannotReuseCachedDetails() async throws {
        let requests = try ProfileRequests()
        let storage = requests.makeStorage()
        try await storage.store("alice", AccountDetails())
        let old = try #require(requests.snapshot)
        requests.snapshot = .init(generation: UUID(), issuer: old.issuer, subject: old.subject)
        requests.profile?.firstName = "Updated"
        try await storage.store("alice", AccountDetails())
        let cached = await storage.load("alice", [])
        #expect(cached?.name?.givenName == "Updated")
        #expect(requests.fetchCount == 2)
        #expect(requests.savedExisting == [true, true])
    }

    @Test
    func delayedDisassociationCannotInvalidateNewSessionForSameSubject() async throws {
        let requests = try ProfileRequests()
        let storage = requests.makeStorage()
        try await storage.store("alice", AccountDetails())
        let old = try #require(requests.snapshot)
        requests.snapshot = .init(generation: UUID(), issuer: old.issuer, subject: old.subject)
        requests.profile?.firstName = "New Session"
        try await storage.store("alice", AccountDetails())
        await storage.disassociate("alice")
        let cached = await storage.load("alice", [])
        #expect(cached?.name?.givenName == "New Session")
        #expect(requests.fetchCount == 2)
        #expect(requests.publications.count == 2)
    }

    @Test
    func concurrentMutationIsRejectedWithoutSecondRequest() async throws {
        let requests = try ProfileRequests()
        let gate = ProfileRequestGate()
        requests.saveGate = gate
        let storage = requests.makeStorage()
        let operation = Task { try await storage.store("alice", AccountDetails()) }
        defer {
            operation.cancel()
            gate.release()
        }
        try await gate.waitUntilStarted()
        await #expect(throws: (any Error).self) {
            try await storage.store("alice", AccountDetails())
        }
        gate.release()
        try await operation.value
        #expect(requests.saveCount == 1)
        #expect(requests.publications.count == 1)
    }

    @Test
    func failedInitialFetchCannotBecomeProfileCreation() async throws {
        let requests = try ProfileRequests()
        requests.fetchError = URLError(.notConnectedToInternet)
        let storage = requests.makeStorage()
        await #expect(throws: TroveAccountError.self) {
            try await storage.store("alice", AccountDetails())
        }
        #expect(requests.saveCount == 0)
        #expect(requests.publications.isEmpty)
    }

    @Test
    func initialFetchErrorDoesNotExposeTransportDetails() async throws {
        let requests = try ProfileRequests()
        requests.fetchError = NSError(
            domain: "SyntheticTransport",
            code: 500,
            userInfo: [NSLocalizedDescriptionKey: "Private response body and bearer token must not be displayed"]
        )
        let storage = requests.makeStorage()
        do {
            try await storage.store("alice", AccountDetails())
            Issue.record("Expected the initial profile fetch to fail.")
        } catch {
            guard case .profileFetchFailed? = error as? TroveAccountError else {
                Issue.record("Expected a safe profile-fetch error.")
                return
            }
            #expect(error.localizedDescription == String(localized: "Could not load your profile."))
            #expect(!error.localizedDescription.contains("bearer token"))
        }
        #expect(requests.saveCount == 0)
        #expect(requests.publications.isEmpty)
    }

    @Test
    func ambiguousSaveRequiresFreshProfileBeforeNextPartialUpdate() async throws {
        let requests = try ProfileRequests()
        let storage = requests.makeStorage()
        var firstChanges = AccountDetails()
        var name = PersonNameComponents()
        name.givenName = "Accepted Remotely"
        name.familyName = "Participant"
        firstChanges.name = name
        requests.saveError = URLError(.networkConnectionLost)
        await #expect(throws: TroveAccountError.self) {
            try await storage.store("alice", firstChanges)
        }
        requests.saveError = nil
        var secondChanges = AccountDetails()
        secondChanges.region = "DE"
        try await storage.store("alice", secondChanges)
        let cached = await storage.load("alice", [])
        #expect(requests.fetchCount == 2)
        #expect(cached?.name?.givenName == "Accepted Remotely")
        #expect(cached?.region == "DE")
        #expect(requests.publications.count == 1)
    }

    @Test
    func partialUpdateLoadsExistingProfileBeforeMerging() async throws {
        let requests = try ProfileRequests()
        let storage = requests.makeStorage()
        var changes = AccountDetails()
        changes.region = "DE"
        try await storage.store("alice", changes)
        let cached = await storage.load("alice", [])
        #expect(cached?.region == "DE")
        #expect(cached?.name?.givenName == "Alice")
        #expect(requests.savedExisting == [true])
    }
}
