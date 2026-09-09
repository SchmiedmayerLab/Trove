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


struct EventDeliverySourceDiscoveryTests {
    @Test
    func reopeningDiscoversPendingActiveAndRevokedStreamsWithoutChangingState() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let pending = try await journal.createSource(localID: UUID(), queryDefinition: Data([1]))
            let active = try await journal.sourceSetup(for: DeliveryFixture.epoch)
            let setup = try await journal.createSource(localID: UUID(), queryDefinition: Data([2]))
            var binding = DeliveryFixture.binding(sourceID: UUID(), registrationID: setup.registrationID)
            binding.revokedAt = binding.createdAt
            let revoked = try await journal.confirmSource(binding, for: setup)
            _ = try await DeliveryFixture.stage(journal, changes: ["retained"])
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let expected = [pending, active, revoked].sorted { $0.localID.uuidString < $1.localID.uuidString }
            let connection = try DeliverySQLite(url: url)
            defer { connection.close() }
            let keyQuery = "SELECT privacy_key FROM source_state ORDER BY local_id"
            let keys = try connection.query(keyQuery) { try DeliverySQLite.blob($0, 0) }
            #expect(try await journal.sourceSetups() == expected)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            do {
                #expect(try await reopened.sourceSetups() == expected)
                #expect(try await reopened.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
                #expect(try connection.query(keyQuery) { try DeliverySQLite.blob($0, 0) } == keys)
            } catch {
                await reopened.close()
                throw error
            }
            await reopened.close()
        }
    }

    @Test(arguments: ["local_id", "privacy_key", "query_definition", "binding", "source_id", "producer_system"])
    func corruptStreamRejectsTheWholeSnapshot(field: String) async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let pending = try await journal.createSource(localID: UUID(), queryDefinition: Data([1]))
            let connection = try DeliverySQLite(url: url)
            defer { connection.close() }
            try connection.execute("PRAGMA ignore_check_constraints = ON")
            let assignments = [
                "local_id": "local_id = 'not-a-uuid'",
                "privacy_key": "privacy_key = x'00'",
                "query_definition": "query_definition = zeroblob(16385)",
                "binding": "binding = x'00'",
                "source_id": "source_id = '00000000-0000-0000-0000-000000000000'",
                "producer_system": "producer_system = 'https://wrong.test/events'"
            ]
            let assignment = try #require(assignments[field])
            try connection.execute(
                "UPDATE source_state SET " + assignment + " WHERE local_id = ?", [.text(DeliveryFixture.epoch.uuidString.lowercased())]
            )
            await #expect(throws: EventDeliveryJournal.JournalError.corruptJournal) { try await journal.sourceSetups() }
            // A valid stream remains intact, but must not mask the broken stream during discovery.
            #expect(try await journal.sourceSetup(for: pending.localID) == pending)
            #expect(try connection.query("SELECT local_id FROM source_state") { try DeliverySQLite.text($0, 0) }.count == 2)
        }
    }

    @Test
    func discoveryNeverSilentlyTruncatesTheSourceLimit() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let connection = try DeliverySQLite(url: url)
            defer { connection.close() }
            try connection.transaction {
                for _ in 1..<512 {
                    try Self.insertPendingSource(connection)
                }
            }
            #expect(try await journal.sourceSetups().count == 512)
            await #expect(throws: EventDeliveryJournal.JournalError.capacityExceeded) {
                try await journal.createSource(localID: UUID(), queryDefinition: Data([1]))
            }
            // Simulate an out-of-band writer exceeding the application limit.
            try Self.insertPendingSource(connection)
            await #expect(throws: EventDeliveryJournal.JournalError.capacityExceeded) { try await journal.sourceSetups() }
        }
    }

    @Test
    func emptyJournalDoesNotCreateAStream() async throws {
        try await DeliveryFixture.withJournal { _, url in
            let empty = try EventDeliveryJournal(
                url: url.deletingLastPathComponent().appendingPathComponent("empty.sqlite"), scope: DeliveryFixture.scope, mode: .createNew
            )
            do {
                #expect(try await empty.sourceSetups().isEmpty)
                #expect(try await empty.sourceSetups().isEmpty)
            } catch {
                await empty.close()
                throw error
            }
            await empty.close()
        }
    }

    @Test
    func cancelledDiscoveryReturnsNoSnapshot() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            await withTaskGroup(of: Void.self) { group in
                group.cancelAll()
                group.addTask {
                    await #expect(throws: CancellationError.self) { try await journal.sourceSetups() }
                }
            }
            let restored = try await journal.sourceSetups()
            #expect(restored.count == 1)
        }
    }
}


extension EventDeliverySourceDiscoveryTests {
    private static func insertPendingSource(_ connection: DeliverySQLite) throws {
        try connection.execute(
            """
            INSERT INTO source_state(local_id, privacy_key, query_definition, next_sequence, checkpoint_revision)
            VALUES (?, zeroblob(32), x'01', 1, ?)
            """,
            [.text(UUID().uuidString.lowercased()), .text(UUID().uuidString.lowercased())]
        )
    }
}
