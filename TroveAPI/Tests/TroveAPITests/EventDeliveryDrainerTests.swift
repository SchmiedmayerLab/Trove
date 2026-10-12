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


struct EventDeliveryDrainerTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [false, true])
    func lostResponseRecoversReceiptAfterReopeningWithoutResubmitting(restrictiveIntent: Bool) async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let payload = DeliveryFixture.payload(sequence: 1, changes: ["change:a"])
            let staged = try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: [
                .init(bytes: payload.bytes, targets: restrictiveIntent ? [] : payload.targets)
            ])
            let id = try #require(staged.first)
            let transport = DeliveryTransport()
            await transport.configure(.loseFirstResponse)
            let drainer = try Self.drainer(journal, transport: transport)
            let first = try await drainer.drain()
            guard case .waiting = try #require(first.first).status else {
                Issue.record("Lost response did not retain a retry deadline")
                return
            }
            #expect(try await journal.receipt(for: id) == nil)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let recovery = try Self.drainer(reopened, transport: transport, at: Self.start.addingTimeInterval(600))
            let second = try await recovery.drain()
            #expect(second.map(\.status) == [.delivered])
            #expect(try await reopened.receipt(for: id) != nil)
            #expect(await transport.submittedBytes.count == 1)
            #expect(await transport.paths.last?.hasSuffix("/event-receipts/lookup") == true)
            await reopened.close()
        }
    }

    @Test
    func lookupMissReplaysExactBytesAndBackoffSurvivesReopening() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let id = try #require(await DeliveryFixture.stage(journal, changes: ["add:a"]).first)
            let transport = DeliveryTransport()
            await transport.configure(.reject(503))
            let drainer = try Self.drainer(journal, transport: transport)
            let first = try await drainer.drain()
            guard case .waiting(let deadline) = try #require(first.first).status else {
                Issue.record("Transient rejection did not persist a retry deadline")
                return
            }
            #expect((4...5).contains(deadline.timeIntervalSince(Self.start)))
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            #expect(try await reopened.status(for: id) == .waiting(until: deadline))
            let tooEarly = try Self.drainer(reopened, transport: transport)
            #expect(try await tooEarly.drain().isEmpty)
            #expect(await transport.paths.count == 1)
            await transport.configure(.accept)
            let ready = try Self.drainer(reopened, transport: transport, at: deadline.addingTimeInterval(1))
            #expect(try await ready.drain().map(\.status) == [.delivered])
            let submitted = await transport.submittedBytes
            #expect(submitted.count == 2)
            #expect(submitted.first == submitted.last)
            await reopened.close()
        }
    }

    @Test(arguments: [400, 403, 404, 409, 413, 422])
    func permanentRejectionBlocksWithoutDeletingPayload(code: Int) async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let id = try #require(await DeliveryFixture.stage(journal, changes: ["add:a"]).first)
            let transport = DeliveryTransport()
            await transport.configure(.reject(code))
            let drainer = try Self.drainer(journal, transport: transport)
            #expect(try await drainer.drain().map(\.status) == [.blocked(.rejected(statusCode: code))])
            #expect(try await journal.pendingDeliveryIDs() == [id])
            #expect(try await drainer.drain().isEmpty)
            #expect(await transport.paths.count == 1)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            #expect(try await reopened.status(for: id) == .blocked(.rejected(statusCode: code)))
            #expect(try await reopened.readyDeliveryIDs(at: Self.start.addingTimeInterval(86400)).isEmpty)
            await reopened.close()
        }
    }

    @Test
    func mismatchedReceiptCannotRetirePayload() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let id = try #require(await DeliveryFixture.stage(journal, changes: ["add:a"]).first)
            let transport = DeliveryTransport()
            await transport.configure(.mismatch)
            let drainer = try Self.drainer(journal, transport: transport)
            #expect(try await drainer.drain().map(\.status) == [.blocked(.invalidReceipt)])
            #expect(try await journal.pendingDeliveryIDs() == [id])
            #expect(try await journal.receipt(for: id) == nil)
        }
    }

    @Test
    func accountChangeDuringReplyPreventsCustodyAndFurtherRequests() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let id = try #require(await DeliveryFixture.stage(journal, changes: ["add:a"]).first)
            let second = try #require(await DeliveryFixture.stage(journal, changes: ["add:b"]).first)
            let transport = DeliveryTransport()
            let session = DeliveryTestSession()
            await transport.onReply { await session.invalidate() }
            let drainer = try Self.drainer(journal, transport: transport, session: session)
            await #expect(throws: EventDeliveryDrainer.DeliveryError.authenticationRequired) { try await drainer.drain() }
            #expect(try await journal.receipt(for: id) == nil)
            #expect(try await journal.receipt(for: second) == nil)
            await #expect(throws: EventDeliveryDrainer.DeliveryError.authenticationRequired) { try await drainer.drain() }
            #expect(await transport.paths.count == 1)
        }
    }

    @Test
    func malformedAcknowledgementRetainsPayloadAndDoesNotRetryImmediately() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let id = try #require(await DeliveryFixture.stage(journal, changes: ["add:a"]).first)
            let transport = DeliveryTransport()
            await transport.configure(.malformedReceipt)
            let drainer = try Self.drainer(journal, transport: transport)
            let results = try await drainer.drain()
            guard case .waiting = try #require(results.first).status else {
                Issue.record("Malformed acknowledgement did not retain a retry deadline")
                return
            }
            #expect(try await journal.pendingDeliveryIDs() == [id])
            #expect(try await journal.receipt(for: id) == nil)
            #expect(try await drainer.drain().isEmpty)
            #expect(await transport.paths.count == 1)
        }
    }

    @Test
    func cancellationRetainsAnUncertainAttempt() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let id = try #require(await DeliveryFixture.stage(journal, changes: ["add:a"]).first)
            let second = try #require(await DeliveryFixture.stage(journal, changes: ["add:b"]).first)
            let transport = DeliveryTransport()
            await transport.onReply { withUnsafeCurrentTask { $0?.cancel() } }
            let drainer = try Self.drainer(journal, transport: transport)
            let task = Task { @concurrent in try await drainer.drain() }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await journal.receipt(for: id) == nil)
            let attempt = try #require(await journal.prepareAttempt(id))
            #expect(attempt.custodyWasUncertain)
            let otherAttempt = try #require(await journal.prepareAttempt(second))
            #expect(otherAttempt.custodyWasUncertain)
        }
    }

    @Test
    func onlySuccessfulMembersRetireAndConcurrentPassIsRejected() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let first = try #require(await DeliveryFixture.stage(journal, changes: ["add:a"]).first)
            _ = try await DeliveryFixture.stage(journal, changes: ["add:b"])
            let transport = DeliveryTransport()
            await transport.configure(.rejectFirst)
            let drainer = try Self.drainer(journal, transport: transport)
            await transport.onReply {
                await #expect(throws: EventDeliveryDrainer.DeliveryError.drainInProgress) { try await drainer.drain() }
            }
            let result = try await drainer.drain()
            #expect(result.map(\.status) == [.blocked(.rejected(statusCode: 422)), .delivered])
            #expect(try await journal.pendingDeliveryIDs() == [first])
            #expect(await transport.submittedBatches.map { $0.events.count } == [2])
        }
    }

    @Test
    func rateLimitHintIsPreservedAndUnauthorizedSessionDoesNotLoop() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            _ = try await DeliveryFixture.stage(journal, changes: ["add:a"])
            let transport = DeliveryTransport()
            await transport.configure(.rateLimit)
            let drainer = try Self.drainer(journal, transport: transport)
            #expect(try await drainer.drain().map(\.status) == [.waiting(until: Self.start.addingTimeInterval(120))])
            await transport.configure(.reject(401))
            let unauthorized = try Self.drainer(journal, transport: transport, at: Self.start.addingTimeInterval(121))
            await #expect(throws: EventDeliveryDrainer.DeliveryError.authenticationRequired) { try await unauthorized.drain() }
            let count = await transport.paths.count
            await #expect(throws: EventDeliveryDrainer.DeliveryError.authenticationRequired) { try await unauthorized.drain() }
            #expect(await transport.paths.count == count)
        }
    }

    @Test
    func aDifferentAccountCannotConstructTheDrain() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let client = Client(
                serverURL: try #require(URL(string: DeliveryFixture.scope.backend)), configuration: .trove, transport: DeliveryTransport()
            )
            let wrong = EventDeliveryJournal.Scope(
                backend: DeliveryFixture.scope.backend, issuer: DeliveryFixture.scope.issuer, subject: "someone-else"
            )
            #expect(throws: EventDeliveryJournal.JournalError.wrongScope) {
                try EventDeliveryDrainer(journal: journal, scope: wrong, client: client, validateSession: {})
            }
        }
    }

    @Test(arguments: ["120", "Fri, 15 Jan 2027 08:02:00 GMT"])
    func unavailableResponsePreservesItsRetryDeadline(header: String) async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            _ = try await DeliveryFixture.stage(journal, changes: ["add:a"])
            let transport = DeliveryTransport()
            await transport.configure(.unavailable(retryAfter: header))
            let drainer = try Self.drainer(journal, transport: transport)
            #expect(try await drainer.drain().map(\.status) == [.waiting(until: Self.start.addingTimeInterval(120))])
        }
    }

    @Test
    func unsupportedRetryDateFallsBackToBoundedBackoff() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            _ = try await DeliveryFixture.stage(journal, changes: ["add:a"])
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            let header = formatter.string(from: Date(timeIntervalSince1970: 253_402_300_800))
            let transport = DeliveryTransport()
            await transport.configure(.unavailable(retryAfter: header))
            let results = try await Self.drainer(journal, transport: transport).drain()
            guard case .waiting(let deadline) = try #require(results.first).status else {
                Issue.record("Unsupported retry date did not retain the event with backoff")
                return
            }
            #expect((4...5).contains(deadline.timeIntervalSince(Self.start)))
        }
    }
}


extension EventDeliveryDrainerTests {
    private static func drainer(
        _ journal: EventDeliveryJournal,
        transport: DeliveryTransport,
        session: DeliveryTestSession = .init(),
        at date: Date = Self.start
    ) throws -> EventDeliveryDrainer {
        try .init(
            journal: journal,
            scope: DeliveryFixture.scope,
            client: Client(serverURL: #require(URL(string: DeliveryFixture.scope.backend)), configuration: .trove, transport: transport),
            validateSession: { try await session.validate() },
            now: { date }
        )
    }
}
