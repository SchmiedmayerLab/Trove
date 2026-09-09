//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPIClient


struct SourceRegistrationTests {
    @Test
    func lostReplyRetriesTheSameRegistrationThenRefreshesBySourceID() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let pending = try await journal.createSource(localID: UUID(), queryDefinition: Data([1]))
            let binding = DeliveryFixture.binding(sourceID: UUID(), registrationID: pending.registrationID)
            let transport = SourceRegistrationTransport(binding: binding, failure: .lostReply)
            await #expect(throws: SourceRegistration.RegistrationError.unavailable) {
                try await Self.synchronize(journal, localID: pending.localID, transport: transport)
            }
            #expect(try await journal.sourceSetup(for: pending.localID) == pending)
            let registered = try await Self.synchronize(journal, localID: pending.localID, transport: transport)
            #expect(registered.binding == binding)
            #expect(try await Self.synchronize(journal, localID: pending.localID, transport: transport) == registered)
            let bodies = await transport.bodies
            #expect(bodies[0] == bodies[1])
            #expect(try JSONDecoder().decode([String: String].self, from: bodies[0]) == ["registrationID": pending.localID.uuidString.lowercased()])
            #expect(await transport.methods == ["POST", "POST", "GET"])
            #expect(await transport.paths.last == "/participant/sources/\(binding.id)")
        }
    }

    @Test(arguments: [false, true])
    func sessionChangesCannotConfirmReplies(afterRequest: Bool) async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let pending = try await journal.createSource(localID: UUID(), queryDefinition: Data([1]))
            let transport = SourceRegistrationTransport(binding: DeliveryFixture.binding(sourceID: UUID(), registrationID: pending.registrationID))
            let session = DeliveryTestSession()
            if afterRequest {
                await transport.onReply { await session.invalidate() }
            } else {
                await session.invalidate()
            }
            await #expect(throws: SourceRegistration.RegistrationError.authenticationRequired) {
                try await Self.synchronize(journal, localID: pending.localID, transport: transport, session: session)
            }
            #expect(try await journal.sourceSetup(for: pending.localID) == pending)
            #expect(await transport.paths.count == (afterRequest ? 1 : 0))
        }
    }

    @Test(arguments: [400, 401, 403, 404, 409, 429, 500, 503])
    func rejectedRefreshNeverRegistersAReplacementOrExposesServerDetails(status: Int) async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let original = try await journal.sourceSetup(for: DeliveryFixture.epoch)
            let transport = SourceRegistrationTransport(binding: try #require(original.binding), status: status)
            let expected: SourceRegistration.RegistrationError = status == 401 ? .authenticationRequired : .rejected(statusCode: status)
            await #expect(throws: expected) { try await Self.synchronize(journal, localID: original.localID, transport: transport) }
            #expect(try await journal.sourceSetup(for: original.localID) == original)
            #expect(await transport.methods == ["GET"])
            #expect(!String(describing: expected).contains("Sensitive upstream detail"))
        }
    }

    @Test
    func malformedReplyDoesNotCreateAnAcceptedBinding() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let pending = try await journal.createSource(localID: UUID(), queryDefinition: Data([1]))
            let transport = SourceRegistrationTransport(
                binding: DeliveryFixture.binding(sourceID: UUID(), registrationID: pending.registrationID), failure: .malformedReply
            )
            await #expect(throws: SourceRegistration.RegistrationError.unavailable) {
                try await Self.synchronize(journal, localID: pending.localID, transport: transport)
            }
            #expect(try await journal.sourceSetup(for: pending.localID) == pending)
        }
    }

    @Test
    func revocationIsRefreshedOnceAndThenRemainsTerminal() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let original = try await journal.sourceSetup(for: DeliveryFixture.epoch)
            var binding = try #require(original.binding)
            binding.revokedAt = binding.createdAt
            let transport = SourceRegistrationTransport(binding: binding)
            let revoked = try await Self.synchronize(journal, localID: original.localID, transport: transport)
            #expect(revoked.binding == binding)
            await transport.replaceBinding(try #require(original.binding))
            #expect(try await Self.synchronize(journal, localID: original.localID, transport: transport) == revoked)
            #expect(await transport.methods == ["GET"])
        }
    }

    @Test
    func lateActiveReplyCannotUndoConcurrentRevocation() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let original = try await journal.sourceSetup(for: DeliveryFixture.epoch)
            let binding = try #require(original.binding)
            let transport = SourceRegistrationTransport(binding: binding)
            await transport.onReply {
                var revoked = binding
                revoked.revokedAt = revoked.createdAt
                try await journal.confirmSource(revoked, for: original)
            }
            await #expect(throws: EventDeliveryJournal.JournalError.sourceConflict) {
                try await Self.synchronize(journal, localID: original.localID, transport: transport)
            }
            #expect(try await journal.sourceSetup(for: original.localID).binding?.revokedAt == binding.createdAt)
        }
    }

    @Test
    func wrongScopeAndMissingSetupPerformNoNetworkRequests() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let transport = SourceRegistrationTransport(binding: DeliveryFixture.binding(sourceID: UUID(), registrationID: UUID()))
            let client = Client(serverURL: try #require(URL(string: DeliveryFixture.scope.backend)), configuration: .trove, transport: transport)
            await #expect(throws: EventDeliveryJournal.JournalError.wrongScope) {
                try await SourceRegistration.synchronize(
                    journal: journal,
                    scope: .init(backend: DeliveryFixture.scope.backend, issuer: DeliveryFixture.scope.issuer, subject: "other"),
                    localID: DeliveryFixture.epoch,
                    client: client,
                    validateSession: {}
                )
            }
            await #expect(throws: EventDeliveryJournal.JournalError.unknownSource) {
                try await Self.synchronize(journal, localID: UUID(), transport: transport)
            }
            #expect(await transport.paths.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func cancellationBeforeOrAfterNetworkingRetainsPendingSetup(afterRequest: Bool) async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let pending = try await journal.createSource(localID: UUID(), queryDefinition: Data([1]))
            let transport = SourceRegistrationTransport(binding: DeliveryFixture.binding(sourceID: UUID(), registrationID: pending.registrationID))
            if afterRequest {
                await transport.onReply {
                    withUnsafeCurrentTask { task in
                        task?.cancel()
                    }
                }
            }
            await withTaskGroup(of: Void.self) { group in
                if !afterRequest { group.cancelAll() }
                group.addTask {
                    await #expect(throws: CancellationError.self) {
                        try await Self.synchronize(journal, localID: pending.localID, transport: transport)
                    }
                }
            }
            #expect(try await journal.sourceSetup(for: pending.localID) == pending)
            #expect(await transport.methods.count == (afterRequest ? 1 : 0))
        }
    }

    @Test
    func overlappingAttemptsConvergeOnOneImmutableBinding() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let pending = try await journal.createSource(localID: UUID(), queryDefinition: Data([1]))
            let binding = DeliveryFixture.binding(sourceID: UUID(), registrationID: pending.registrationID)
            let transport = SourceRegistrationTransport(binding: binding)
            // SourceSetup contains the same large binding that triggers Swift 6.3's async-let teardown failure.
            let (left, right) = try await withThrowingTaskGroup(of: EventDeliveryJournal.SourceSetup.self) { requests in
                requests.addTask { try await Self.synchronize(journal, localID: pending.localID, transport: transport) }
                requests.addTask { try await Self.synchronize(journal, localID: pending.localID, transport: transport) }
                let first = try #require(try await requests.next())
                let second = try #require(try await requests.next())
                return (first, second)
            }
            #expect(left == right)
            #expect(left.binding == binding)
            #expect(try await journal.sourceSetup(for: pending.localID) == left)
        }
    }

    @Test
    func sessionLossAfterCommitSuppressesTheResultWithoutUndoingCorrectlyScopedState() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let pending = try await journal.createSource(localID: UUID(), queryDefinition: Data([1]))
            let binding = DeliveryFixture.binding(sourceID: UUID(), registrationID: pending.registrationID)
            let transport = SourceRegistrationTransport(binding: binding)
            let client = Client(serverURL: try #require(URL(string: DeliveryFixture.scope.backend)), configuration: .trove, transport: transport)
            await #expect(throws: SourceRegistration.RegistrationError.authenticationRequired) {
                try await SourceRegistration.synchronize(
                    journal: journal,
                    scope: DeliveryFixture.scope,
                    localID: pending.localID,
                    client: client,
                    validateSession: {
                        // Lose this session immediately after the durable commit, not after a timing delay.
                        if try await journal.sourceSetup(for: pending.localID).binding != nil { throw CancellationError() }
                    }
                )
            }
            #expect(try await journal.sourceSetup(for: pending.localID).binding == binding)
            #expect(journal.scope == DeliveryFixture.scope)
        }
    }
}


extension SourceRegistrationTests {
    private static func synchronize(
        _ journal: EventDeliveryJournal, localID: UUID, transport: SourceRegistrationTransport, session: DeliveryTestSession = .init()
    ) async throws -> EventDeliveryJournal.SourceSetup {
        try await SourceRegistration.synchronize(
            journal: journal,
            scope: DeliveryFixture.scope,
            localID: localID,
            client: Client(serverURL: #require(URL(string: DeliveryFixture.scope.backend)), configuration: .trove, transport: transport),
            validateSession: { try await session.validate() }
        )
    }
}
