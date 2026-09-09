//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SQLKit
import Testing
import TroveAPIClient
@testable import TroveServer
import VaporTesting


/// Second collection configuration: paged, filtered acquisition while offline,
/// followed by delayed batching for one study. No HealthKit, UI or scheduler dependency.
/// The validator transport is isolated; this tests delivery, not FHIR conformance.
struct ClientBackfillDeliveryTests {
    private struct Staged: Sendable {
        let identifiers: [UUID]
        let payloads: [EventDeliveryJournal.Payload]
        let checkpoint: EventDeliveryJournal.Checkpoint
    }

    @Test
    func pagedBackfillRecoversLostBatchWithoutResubmittingAcceptedEvents() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant"), validator: ClinicalEventBatchTests.validator()) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("trove-backfill-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("delivery.sqlite")
            let scope = try EventDeliveryJournal.Scope(
                backend: Servers.Server1.url().absoluteString, issuer: TestApp.issuer, subject: "test-participant"
            )
            let staged = try await ClientDeliveryRecoveryTests.withJournal(url: url, scope: scope, mode: .createNew) { journal in
                try await Self.stagePages(journal: journal, fixture: fixture)
            }
            // Reopen before any network request: acquisition does not depend on an uploader staying alive.
            try await ClientDeliveryRecoveryTests.withJournal(url: url, scope: scope, mode: .openExisting) { journal in
                try await Self.deliver(staged, journal: journal, fixture: fixture, on: app, token: token)
            }
            try await TestDatabase.withRestartedApplication(app) { reopened in
                await configureServices(
                    for: reopened, storageProvider: InMemoryObjectStorageProvider(), validator: ClinicalEventBatchTests.validator()
                )
                _ = try await TestApp.configureTransport(for: reopened)
                try await ClientDeliveryRecoveryTests.withJournal(url: url, scope: scope, mode: .openExisting) { journal in
                    try await Self.recover(staged, journal: journal, fixture: fixture, on: reopened, token: token)
                }
            }
        }
    }
}


extension ClientBackfillDeliveryTests {
    private static func stagePages(journal: EventDeliveryJournal, fixture: ClinicalEventStoreTests.Fixture) async throws -> Staged {
        let setup = try await journal.createSource(
            localID: fixture.source.registrationID, queryDefinition: Data("synthetic-paged-backfill-v1".utf8)
        )
        try await journal.confirmSource(.init(fixture.source), for: setup)
        let payloads = try (1...18).map { sequence in
            let bytes = try LocalPointEventFixture.bytes(source: fixture.source, sequence: UInt64(sequence), recordID: "sample-\(sequence)")
            let projection = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-target-selection-only")
            return EventDeliveryJournal.Payload(bytes: bytes, targets: fixture.targets(for: projection, studies: [1]).map {
                .init(consentID: $0.consentID, outputFullURLs: $0.outputFullURLs)
            })
        }
        try #require(Set(payloads.flatMap { $0.targets.flatMap(\.outputFullURLs) }).count == 18)
        var identifiers: [UUID] = []
        for page in 1...2 {
            let checkpoint = try await journal.checkpoint(for: fixture.source.id)
            let cursor = Data("page-\(page)".utf8)
            let ids = try await journal.stage(from: checkpoint, nextCursor: cursor, changeCount: 10) { index, sequence in
                // Caller-owned selection filters one source change without losing page progress
                // or consuming an event sequence. The shared journal knows no study policy.
                guard index != 0 else {
                    return nil
                }
                try #require((1...18).contains(sequence))
                return payloads[Int(sequence) - 1]
            }
            #expect(ids.count == 9)
            identifiers.append(contentsOf: ids)
            await #expect(throws: EventDeliveryJournal.JournalError.staleCheckpoint) {
                try await journal.stage(from: checkpoint, nextCursor: cursor, changeCount: 0) { _, _ in nil }
            }
        }
        #expect(identifiers.count == 18)
        return Staged(identifiers: identifiers, payloads: payloads, checkpoint: try await journal.checkpoint(for: fixture.source.id))
    }

    private static func deliver(
        _ staged: Staged, journal: EventDeliveryJournal, fixture: ClinicalEventStoreTests.Fixture, on app: Application, token: String?
    ) async throws {
        #expect(try await journal.checkpoint(for: fixture.source.id) == staged.checkpoint)
        #expect(try await journal.pendingDeliveryIDs(limit: 128) == staged.identifiers)
        try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
        let transport = ReceiverClientTransport(application: app, token: token, loseBatchResponse: true)
        let results = try await ClientDeliveryRecoveryTests.drainer(journal: journal, transport: transport).drain(limit: 128)
        #expect(results.map(\.deliveryID) == staged.identifiers)
        #expect(results.suffix(2).map(\.status) == [.delivered, .delivered])
        for result in results.prefix(16) {
            guard case .waiting = result.status else {
                Issue.record("The lost first batch must remain uncertain while the second batch succeeds")
                continue
            }
            #expect(try await journal.receipt(for: result.deliveryID) == nil)
        }
        let batches = await transport.batchBodies
        try #require(batches.count == 2)
        try ClientDeliveryRecoveryTests.expectPayloads(batches[0], equalTo: Array(staged.payloads.prefix(16)))
        try ClientDeliveryRecoveryTests.expectPayloads(batches[1], equalTo: Array(staged.payloads.suffix(2)))
        try await expectStored(staged, fixture: fixture, on: app)
    }

    private static func recover(
        _ staged: Staged, journal: EventDeliveryJournal, fixture: ClinicalEventStoreTests.Fixture, on app: Application, token: String?
    ) async throws {
        #expect(try await journal.checkpoint(for: fixture.source.id) == staged.checkpoint)
        let transport = ReceiverClientTransport(application: app, token: token)
        let drainer = try ClientDeliveryRecoveryTests.drainer(
            journal: journal, transport: transport, now: Date().addingTimeInterval(600)
        )
        let results = try await drainer.drain(limit: 128)
        #expect(results.map(\.deliveryID) == Array(staged.identifiers.prefix(16)))
        #expect(results.allSatisfy { $0.status == .delivered })
        #expect(await transport.paths.count == 16)
        #expect(await transport.paths.allSatisfy { $0.hasSuffix("/event-receipts/lookup") })
        #expect(await transport.batchBodies.isEmpty)
        for (id, payload) in zip(staged.identifiers, staged.payloads) {
            let receipt = try #require(try await journal.receipt(for: id))
            try EventSubmissionCommitment(sourceID: fixture.source.id, originalBytes: payload.bytes, targets: payload.targets).verify(receipt)
        }
        try await expectStored(staged, fixture: fixture, on: app)
        #expect(try await journal.pruneDelivered() == 18)
        #expect(try await journal.pendingDeliveryIDs().isEmpty)
        #expect(try await journal.checkpoint(for: fixture.source.id) == staged.checkpoint)
    }

    private static func expectStored(_ staged: Staged, fixture: ClinicalEventStoreTests.Fixture, on app: Application) async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        let rows = try await sql.raw("SELECT raw_bytes FROM clinical_events").all()
        #expect(rows.count == 18)
        #expect(try Set(rows.map { try $0.decode(column: "raw_bytes", as: Data.self) }) == Set(staged.payloads.map(\.bytes)))
        let store = ClinicalEventStore(database: app.db)
        #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 0)
        let visiblePoints = try await store.effectiveGrantCount(studyID: fixture.studyIDs[1])
        #expect(visiblePoints == 18)
    }
}
