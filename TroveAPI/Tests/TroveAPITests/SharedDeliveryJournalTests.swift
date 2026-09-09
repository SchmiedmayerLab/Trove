//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import TroveAPIClient


@Suite
struct SharedDeliveryJournalTests {
    private typealias Journal = DeliveryJournal<JournalFixture>

    @Test
    func independentWireContractPreservesExactCustodyAcrossReopening() async throws {
        try await withJournal { journal, url, sourceID in
            let checkpoint = try await journal.checkpoint(for: sourceID)
            let bytes = try JSONEncoder().encode(FixtureEvent(sourceID: sourceID, sequence: 1))
            let ids = try await journal.stage(from: checkpoint, nextCursor: Data([1]), changeCount: 1) { _, _ in
                .init(bytes: bytes, targets: ["study-b", "study-a"])
            }
            let id = try #require(ids.first)
            let attempt = try #require(await journal.prepareAttempt(id))
            #expect(attempt.bytes == bytes)
            #expect(!attempt.custodyWasUncertain)
            await #expect(throws: FixtureError.self) { try await journal.recordReceipt("unrelated", for: id) }
            #expect(try await journal.status(for: id) == .pending)
            await journal.close()

            let reopened = try Journal(url: url, scope: JournalFixture.scope, mode: .openExisting)
            let recovered = try #require(await reopened.prepareAttempt(id))
            #expect(recovered.bytes == bytes)
            #expect(recovered.custodyWasUncertain)
            #expect(recovered.commitment.metadata == attempt.commitment.metadata)
            let receipt = JournalFixture.acknowledgement(recovered.commitment.metadata)
            try await reopened.recordReceipt(receipt, for: id)
            await reopened.close()

            let delivered = try Journal(url: url, scope: JournalFixture.scope, mode: .openExisting)
            #expect(try await delivered.receipt(for: id) == receipt)
            #expect(try await delivered.status(for: id) == .delivered)
            #expect(try await delivered.pruneDelivered() == 1)
            #expect(try await delivered.checkpoint(for: sourceID).cursor == Data([1]))
            await delivered.close()
        }
    }

    @Test
    func failedMemberRollsBackTheEntireDelta() async throws {
        try await withJournal { journal, _, sourceID in
            let checkpoint = try await journal.checkpoint(for: sourceID)
            await #expect(throws: FixtureError.self) {
                try await journal.stage(from: checkpoint, nextCursor: Data([2]), changeCount: 2) { index, sequence in
                    guard index == 0 else { throw FixtureError.invalid }
                    return .init(bytes: try JSONEncoder().encode(FixtureEvent(sourceID: sourceID, sequence: sequence)), targets: ["study"])
                }
            }
            #expect(try await journal.checkpoint(for: sourceID) == checkpoint)
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
            let ids = try await journal.stage(from: checkpoint, nextCursor: Data([1]), changeCount: 1) { _, sequence in
                #expect(sequence == 1)
                return .init(bytes: try JSONEncoder().encode(FixtureEvent(sourceID: sourceID, sequence: sequence)), targets: ["study"])
            }
            #expect(ids.count == 1)
        }
    }

    @Test
    func incompatibleContractCannotOpenOrAlterEstablishedState() async throws {
        try await withJournal { journal, url, sourceID in
            let checkpoint = try await journal.checkpoint(for: sourceID)
            await journal.close()
            let before = try Data(contentsOf: url)
            #expect(throws: DeliveryJournalError.wrongScope) {
                try DeliveryJournal<OtherJournalFixture>(url: url, scope: JournalFixture.scope, mode: .openExisting)
            }
            #expect(try Data(contentsOf: url) == before)
            let restored = try Journal(url: url, scope: JournalFixture.scope, mode: .openExisting)
            #expect(try await restored.checkpoint(for: sourceID) == checkpoint)
            await restored.close()
        }
    }

    @Test(arguments: [4, 999])
    func incompatibleSchemaIsRejectedWithoutRecreatingState(version: Int64) async throws {
        try await withJournal { journal, url, _ in
            await journal.close()
            let connection = try DeliverySQLite(url: url)
            try connection.execute("PRAGMA user_version = \(version)")
            connection.close()
            let before = try Data(contentsOf: url)
            #expect(throws: DeliveryJournalError.unsupportedFormat) {
                try Journal(url: url, scope: JournalFixture.scope, mode: .openExisting)
            }
            #expect(try Data(contentsOf: url) == before)
        }
    }

    private func withJournal(_ operation: (Journal, URL, UUID) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("trove-delivery-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        #if os(iOS) || os(watchOS) || os(visionOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        var protectedDirectory = directory
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(resources)
        #endif
        let url = directory.appendingPathComponent("delivery.sqlite")
        let journal = try Journal(url: url, scope: JournalFixture.scope, mode: .createNew)
        do {
            let setup = try await journal.createSource(localID: UUID(), queryDefinition: Data([1]))
            let sourceID = UUID()
            try await journal.confirmSource(.init(id: sourceID, registrationID: setup.localID), for: setup)
            try await operation(journal, url, sourceID)
            await journal.close()
        } catch {
            await journal.close()
            throw error
        }
    }
}
