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


struct EventDeliveryBatchTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func countBoundCreatesThreeBatchesWithoutReordering() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let ids = try await Self.stage(journal, count: 34)
            let transport = DeliveryTransport()
            let results = try await Self.drainer(journal, transport: transport).drain(limit: 128)
            #expect(results.map(\.deliveryID) == ids)
            #expect(results.map(\.status) == Array(repeating: .delivered, count: 34))
            #expect(await transport.submittedBatches.map { $0.events.count } == [16, 16, 2])
            #expect(await transport.paths.count == 3)
        }
    }

    @Test(arguments: [(DeliveryTransport.Behavior.loseFirstResponse, [0, 1, 2]), (.partialLoss(2), [0, 1, 2, 2])])
    func lostReplyRecoversEachMemberAfterReopening(behavior: DeliveryTransport.Behavior, expectedPayloadIndices: [Int]) async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let ids = try await Self.stage(journal, count: 3)
            let transport = DeliveryTransport()
            await transport.configure(behavior)
            let results = try await Self.drainer(journal, transport: transport).drain()
            #expect(results.allSatisfy(Self.waiting))
            for id in ids { #expect(try await journal.receipt(for: id) == nil) }
            let originals = await transport.submittedBytes
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let recovery = try Self.drainer(reopened, transport: transport, at: Self.start.addingTimeInterval(600))
            #expect(try await recovery.drain().map(\.status) == [.delivered, .delivered, .delivered])
            #expect(await transport.paths.filter { $0.hasSuffix("/event-receipts/lookup") }.count == 3)
            let submitted = await transport.submittedBytes
            #expect(submitted == expectedPayloadIndices.map { originals[$0] })
            for id in ids { #expect(try await reopened.receipt(for: id) != nil) }
            await reopened.close()
        }
    }

    @Test(arguments: [-1, 1])
    func missingOrExtraResultsRetainAllMembers(delta: Int) async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let ids = try await Self.stage(journal, count: 2)
            let transport = DeliveryTransport()
            await transport.configure(.responseCountDelta(delta))
            let result = try await Self.drainer(journal, transport: transport).drain()
            #expect(result.allSatisfy(Self.waiting))
            #expect(try await journal.pendingDeliveryIDs() == ids)
            for id in ids { #expect(try await journal.receipt(for: id) == nil) }
            let recovered = try Self.drainer(journal, transport: transport, at: Self.start.addingTimeInterval(600))
            #expect(try await recovered.drain().map(\.status) == [.delivered, .delivered])
            #expect(await transport.submittedBatches.count == 1)
        }
    }

    @Test(arguments: [200, 399, 600])
    func invalidProblemStatusCannotRetireOrPermanentlyRejectMembers(code: Int) async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let ids = try await Self.stage(journal, count: 2)
            let transport = DeliveryTransport()
            await transport.configure(.problemStatus(code))
            #expect(try await Self.drainer(journal, transport: transport).drain().allSatisfy(Self.waiting))
            #expect(try await journal.pendingDeliveryIDs() == ids)
            for id in ids { #expect(try await journal.receipt(for: id) == nil) }
        }
    }

    @Test
    func unauthorizedMemberStopsBeforeCommittingSiblingReceipts() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let ids = try await Self.stage(journal, count: 2)
            let transport = DeliveryTransport()
            await transport.configure(.problemStatus(401))
            let drainer = try Self.drainer(journal, transport: transport)
            await #expect(throws: EventDeliveryDrainer.DeliveryError.authenticationRequired) { try await drainer.drain() }
            for id in ids { #expect(try await journal.receipt(for: id) == nil) }
            await #expect(throws: EventDeliveryDrainer.DeliveryError.authenticationRequired) { try await drainer.drain() }
            #expect(await transport.paths.count == 1)
        }
    }

    @Test
    func oneInvalidReceiptCannotDiscardAValidSibling() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let ids = try await Self.stage(journal, count: 2)
            let transport = DeliveryTransport()
            await transport.configure(.mismatchFirst)
            let result = try await Self.drainer(journal, transport: transport).drain()
            #expect(result.map(\.status) == [.blocked(.invalidReceipt), .delivered])
            #expect(try await journal.pendingDeliveryIDs() == [ids[0]])
            #expect(try await journal.receipt(for: ids[0]) == nil)
            #expect(try await journal.receipt(for: ids[1]) != nil)
        }
    }

    @Test
    func reorderedReceiptsAreNotAssignedToDifferentEvents() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let ids = try await Self.stage(journal, count: 2)
            let transport = DeliveryTransport()
            await transport.configure(.reverseResults)
            let result = try await Self.drainer(journal, transport: transport).drain()
            #expect(result.map(\.status) == [.blocked(.invalidReceipt), .blocked(.invalidReceipt)])
            #expect(try await journal.pendingDeliveryIDs() == ids)
        }
    }

    @Test
    func changingSourcesFlushesTheEnvelopeWithoutChangingQueueOrder() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            var ids = try await Self.stage(journal, count: 1)
            let other = UUID()
            try await DeliveryFixture.register(journal, sourceID: other, query: Data([2]))
            ids += try await Self.stage(journal, count: 1, sourceID: other)
            ids += try await Self.stage(journal, count: 1)
            let transport = DeliveryTransport()
            let result = try await Self.drainer(journal, transport: transport).drain()
            #expect(result.map(\.deliveryID) == ids)
            #expect(result.map(\.status) == [.delivered, .delivered, .delivered])
            #expect(await transport.batchSourceIDs == [DeliveryFixture.sourceID, other, DeliveryFixture.sourceID])
        }
    }

    @Test(arguments: [2_500_000, 4 * 1024 * 1024])
    func payloadBoundSplitsRequestsAndPreservesMaximumSizedEvents(size: Int) async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            _ = try await Self.stage(journal, count: 2, byteCount: size)
            let transport = DeliveryTransport()
            #expect(try await Self.drainer(journal, transport: transport).drain().map(\.status) == [.delivered, .delivered])
            #expect(await transport.submittedBatches.map { $0.events.count } == [1, 1])
            #expect(await transport.submittedBytes.map(\.count) == [size, size])
            #expect(await transport.batchBodyBytes.allSatisfy { $0 <= 6 * 1024 * 1024 })
        }
    }

    @Test
    func intentBytesAlsoBoundTheEnvelope() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let outputs = (0..<480).map { "urn:output:\($0):" + String(repeating: "a", count: 480) }
            let targets = [DeliveryFixture.consentID, UUID()].map { EventTargetIntent.Target(consentID: $0, outputFullURLs: outputs) }
            _ = try await Self.stage(journal, count: 16, targets: targets)
            let transport = DeliveryTransport()
            let result = try await Self.drainer(journal, transport: transport).drain()
            #expect(result.map(\.status) == Array(repeating: .delivered, count: 16))
            let batches = await transport.submittedBatches
            #expect(batches.count == 2)
            #expect(batches.flatMap(\.events).count == 16)
            #expect(await transport.batchBodyBytes.allSatisfy { $0 <= 6 * 1024 * 1024 })
        }
    }
}


extension EventDeliveryBatchTests {
    private static func stage(
        _ journal: EventDeliveryJournal,
        count: Int,
        sourceID: UUID = DeliveryFixture.sourceID,
        byteCount: Int? = nil,
        targets: [EventTargetIntent.Target] = [.init(consentID: DeliveryFixture.consentID, outputFullURLs: ["urn:output:a"])]
    ) async throws -> [UUID] {
        let checkpoint = try await journal.checkpoint(for: sourceID)
        let producer = UUID()
        let payloads = try (0..<count).map { index -> EventDeliveryJournal.Payload in
            let payload = DeliveryFixture.payload(sequence: Int64(index + 1), changes: ["sample"], sourceID: sourceID, producerID: producer)
            let size = byteCount ?? payload.bytes.count
            try #require(size >= payload.bytes.count)
            let bytes = payload.bytes + Data(repeating: 32, count: size - payload.bytes.count)
            return .init(bytes: bytes, targets: targets)
        }
        return try await journal.stage(from: checkpoint, nextCursor: Data(UUID().uuidString.utf8), payloads: payloads)
    }

    private static func waiting(_ result: EventDeliveryDrainer.Outcome) -> Bool {
        if case .waiting = result.status { true } else { false }
    }

    private static func drainer(
        _ journal: EventDeliveryJournal, transport: DeliveryTransport, at date: Date = Self.start
    ) throws -> EventDeliveryDrainer {
        try .init(
            journal: journal,
            scope: DeliveryFixture.scope,
            client: Client(serverURL: #require(URL(string: DeliveryFixture.scope.backend)), configuration: .trove, transport: transport),
            validateSession: {},
            now: { date }
        )
    }
}
