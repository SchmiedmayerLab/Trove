//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import CTroveDeliverySQLite
import Foundation
import Testing
@testable import TroveAPIClient


struct SensorKitJournalMigrationTests {
    @Test
    func additiveMigrationPreservesQueuedBytesAttemptsAndCursor() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let ids = try await DeliveryFixture.stage(journal, changes: ["queued-before-replay"])
            let id = try #require(ids.first)
            let original = try #require(await journal.prepareAttempt(id))
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            await journal.close()
            try makeVersion17(url)
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            #expect(try await reopened.pendingDeliveryIDs() == ids)
            #expect(try await reopened.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
            let retry = try #require(await reopened.prepareAttempt(id))
            #expect(retry.bytes == original.bytes)
            #expect(retry.commitment.receiptLookup == original.commitment.receiptLookup)
            #expect(retry.custodyWasUncertain)
            await reopened.close()
            #expect(try schemaVersion(url) == 19)
            let second = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            #expect(try await second.pendingDeliveryIDs() == ids)
            await second.close()
        }
    }

    @Test
    func wrongScopeCannotMigrateOrRewriteVersion17() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            _ = try await DeliveryFixture.stage(journal, changes: ["retained"])
            await journal.close()
            try makeVersion17(url)
            let original = try Data(contentsOf: url)
            let wrong = DeliveryScope(backend: DeliveryFixture.scope.backend, issuer: DeliveryFixture.scope.issuer, subject: "other-account")
            #expect(throws: DeliveryJournalError.wrongScope) {
                try EventDeliveryJournal(url: url, scope: wrong, mode: .openExisting)
            }
            #expect(try Data(contentsOf: url) == original)
            #expect(try schemaVersion(url) == 17)
        }
    }

    @Test
    func logicalBudgetFailureRollsBackAllMigrationDDL() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let ids = try await DeliveryFixture.stage(journal, changes: ["retained"])
            await journal.close()
            try makeVersion17(url)
            let original = try Data(contentsOf: url)
            #expect(throws: DeliveryJournalError.capacityExceeded) {
                try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting, limits: .init(maximumBytes: 1))
            }
            #expect(try Data(contentsOf: url) == original)
            #expect(try schemaVersion(url) == 17)
            let inspection = try DeliverySQLite(url: url)
            #expect(try inspection.query("SELECT name FROM sqlite_master WHERE name LIKE 'sensorkit_%'", read: {
                try DeliverySQLite.text($0, 0)
            }).isEmpty)
            inspection.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            #expect(try await reopened.pendingDeliveryIDs() == ids)
            await reopened.close()
        }
    }

    @Test
    func physicalBudgetFailurePreservesQueuedVersion17() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let ids = try await DeliveryFixture.stage(journal, changes: ["retained"])
            await journal.close()
            try makeVersion17(url)
            let database = try DeliverySQLite(url: url)
            try database.execute("VACUUM")
            let pages = try #require(database.query("PRAGMA page_count") { sqlite3_column_int64($0, 0) }.first)
            let pageSize = try #require(database.query("PRAGMA page_size") { sqlite3_column_int64($0, 0) }.first)
            database.close()
            let byteLimit = Int(pages * pageSize)
            try #require(byteLimit >= 65_536)
            let original = try Data(contentsOf: url)
            #expect(throws: DeliverySQLite.Failure.self) {
                try EventDeliveryJournal(
                    url: url, scope: DeliveryFixture.scope, mode: .openExisting, limits: .init(maximumDatabaseBytes: byteLimit)
                )
            }
            #expect(try Data(contentsOf: url) == original)
            #expect(try schemaVersion(url) == 17)
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            #expect(try await reopened.pendingDeliveryIDs() == ids)
            await reopened.close()
        }
    }

    private func makeVersion17(_ url: URL) throws {
        // Only removes the new, empty additive tables from this test's own disposable journal.
        let database = try DeliverySQLite(url: url)
        defer { database.close() }
        try database.transaction {
            try database.execute("DROP TABLE sensorkit_recording_slice")
            try database.execute("DROP TABLE sensorkit_batch_evidence")
            try database.execute("PRAGMA user_version = 17")
        }
    }

    private func schemaVersion(_ url: URL) throws -> Int64 {
        let database = try DeliverySQLite(url: url)
        defer { database.close() }
        return try #require(database.query("PRAGMA user_version") { sqlite3_column_int64($0, 0) }.first)
    }
}
