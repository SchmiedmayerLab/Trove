//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import Testing
@testable import TroveAPIClient


struct EventDeliverySourceSetupTests {
    @Test
    func interruptedSetupRestoresTheSameNonceKeyAndConversionIdentity() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let localID = UUID()
            let sourceID = UUID()
            let pending = try await journal.createSource(localID: localID, queryDefinition: Data([7]))
            #expect(pending.registrationID == localID)
            #expect(pending.binding == nil)
            await #expect(throws: EventDeliveryJournal.JournalError.unknownSource) { try await journal.checkpoint(for: sourceID) }
            let connection = try DeliverySQLite(url: url)
            let keySQL = "SELECT privacy_key FROM source_state WHERE local_id = ?"
            let keyBefore = try connection.query(keySQL, [.text(localID.uuidString.lowercased())]) {
                try DeliverySQLite.blob($0, 0)
            }
            connection.close()
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let restored = try await reopened.sourceSetup(for: localID)
            #expect(restored == pending)
            let response = DeliveryFixture.binding(sourceID: sourceID, registrationID: restored.registrationID)
            let confirmed = try await reopened.confirmSource(response, for: restored)
            #expect(try await reopened.confirmSource(response, for: pending) == confirmed)
            let identity = try await Self.recordIdentity(reopened, sourceID: sourceID)
            await reopened.close()
            try await Self.expectRestored(url: url, setup: confirmed, key: keyBefore, identity: identity, sourceID: sourceID)
        }
    }

    @Test(arguments: ["nonce", "participant", "namespace", "event", "time"])
    func invalidReplyLeavesSetupPending(field: String) async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let setup = try await journal.createSource(localID: UUID(), queryDefinition: Data([1]))
            let sourceID = UUID()
            var response = DeliveryFixture.binding(sourceID: sourceID, registrationID: setup.registrationID)
            switch field {
            case "nonce": response.registrationID = UUID().uuidString
            case "participant": response.participantIdentifier.system = "https://another.test/participants"
            case "namespace": response.identifierRoot = "/relative"
            case "event": response.eventIdentifierSystem = "https://foreign.test/events"
            default: response.revokedAt = response.createdAt.addingTimeInterval(-1)
            }
            await #expect(throws: EventDeliveryJournal.JournalError.invalidSourceBinding) { try await journal.confirmSource(response, for: setup) }
            #expect(try await journal.sourceSetup(for: setup.localID) == setup)
            await #expect(throws: EventDeliveryJournal.JournalError.unknownSource) { try await journal.identityScope(for: sourceID) }
        }
    }

    @Test
    func concurrentCreationHasOneWinnerWithoutReplacingEstablishedSetup() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let localID = UUID()
            let successes = try await withThrowingTaskGroup(of: Int.self, returning: Int.self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        do {
                            _ = try await journal.createSource(localID: localID, queryDefinition: Data([1]))
                            return 1
                        } catch EventDeliveryJournal.JournalError.sourceConflict {
                            return 0
                        }
                    }
                }
                return try await group.reduce(0, +)
            }
            #expect(successes == 1)
            #expect(try await journal.sourceSetup(for: localID).queryDefinition == Data([1]))
        }
    }

    @Test
    func revocationBlocksConversionAndStagingButPreservesReceiptRecovery() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let ids = try await DeliveryFixture.stage(journal, changes: ["retain"])
            let id = try #require(ids.first)
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let setup = try await journal.sourceSetup(for: DeliveryFixture.epoch)
            let active = try #require(setup.binding)
            var revoked = active
            revoked.revokedAt = active.createdAt.addingTimeInterval(1)
            try await journal.confirmSource(revoked, for: setup)
            await #expect(throws: EventDeliveryJournal.JournalError.sourceConflict) { try await journal.confirmSource(active, for: setup) }
            await #expect(throws: EventDeliveryJournal.JournalError.sourceRevoked) { try await journal.identityScope(for: DeliveryFixture.sourceID) }
            await #expect(throws: EventDeliveryJournal.JournalError.sourceRevoked) {
                try await journal.stage(from: checkpoint, nextCursor: Data([1]), payloads: [])
            }
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
            let attempt = try #require(try await journal.prepareAttempt(id))
            try await journal.recordReceipt(DeliveryFixture.receipt(attempt), for: id)
            #expect(try await journal.status(for: id) == .delivered)
        }
    }

    @Test
    func missingOrDamagedKeyIsNotRegeneratedDuringRestoration() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            await #expect(throws: EventDeliveryJournal.JournalError.unknownSource) { try await journal.sourceSetup(for: UUID()) }
            let connection = try DeliverySQLite(url: url)
            try connection.execute("PRAGMA ignore_check_constraints = ON")
            try connection.execute("UPDATE source_state SET privacy_key = x'00'")
            connection.close()
            await #expect(throws: EventDeliveryJournal.JournalError.corruptJournal) { try await journal.sourceSetup(for: DeliveryFixture.epoch) }
            await #expect(throws: EventDeliveryJournal.JournalError.sourceConflict) {
                try await journal.createSource(localID: DeliveryFixture.epoch, queryDefinition: DeliveryFixture.queryDefinition)
            }
            await #expect(throws: EventDeliveryJournal.JournalError.corruptJournal) { try await journal.identityScope(for: DeliveryFixture.sourceID) }
        }
    }

    @Test
    func setupCannotCrossAccountScope() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let original = try await journal.sourceSetup(for: DeliveryFixture.epoch)
            let other = try EventDeliveryJournal(
                url: url.deletingLastPathComponent().appendingPathComponent("other.sqlite"),
                scope: .init(backend: DeliveryFixture.scope.backend, issuer: DeliveryFixture.scope.issuer, subject: "other"),
                mode: .createNew
            )
            let response = try #require(original.binding)
            await #expect(throws: EventDeliveryJournal.JournalError.wrongScope) { try await other.confirmSource(response, for: original) }
            await other.close()
        }
    }

    @Test(arguments: [true, false])
    func capacityFailureNeverLeavesPartialSetup(failsCreation: Bool) async throws {
        try await DeliveryFixture.withJournal { _, url in
            let journal = try EventDeliveryJournal(
                url: url.deletingLastPathComponent().appendingPathComponent("bounded.sqlite"),
                scope: DeliveryFixture.scope,
                mode: .createNew,
                limits: .init(maximumBytes: failsCreation ? 32 : 100)
            )
            let localID = UUID()
            if failsCreation {
                await #expect(throws: EventDeliveryJournal.JournalError.capacityExceeded) {
                    try await journal.createSource(localID: localID, queryDefinition: Data([1]))
                }
                await #expect(throws: EventDeliveryJournal.JournalError.unknownSource) { try await journal.sourceSetup(for: localID) }
            } else {
                let pending = try await journal.createSource(localID: localID, queryDefinition: Data([1]))
                let response = DeliveryFixture.binding(sourceID: UUID(), registrationID: localID)
                await #expect(throws: EventDeliveryJournal.JournalError.capacityExceeded) { try await journal.confirmSource(response, for: pending) }
                #expect(try await journal.sourceSetup(for: localID) == pending)
            }
            await journal.close()
        }
    }

    @Test
    func cancelledCreationDoesNotAllocateDurableState() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let localID = UUID()
            await withTaskGroup(of: Void.self) { group in
                group.cancelAll()
                group.addTask {
                    await #expect(throws: CancellationError.self) { try await journal.createSource(localID: localID, queryDefinition: Data([1])) }
                }
            }
            await #expect(throws: EventDeliveryJournal.JournalError.unknownSource) { try await journal.sourceSetup(for: localID) }
        }
    }

    @Test
    func firstReplyMayAlreadyBeRevokedButCannotEnableConversion() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let pending = try await journal.createSource(localID: UUID(), queryDefinition: Data([1]))
            let sourceID = UUID()
            var response = DeliveryFixture.binding(sourceID: sourceID, registrationID: pending.registrationID)
            response.revokedAt = response.createdAt
            let restored = try await journal.confirmSource(response, for: pending)
            #expect(restored.binding == response)
            await #expect(throws: EventDeliveryJournal.JournalError.sourceRevoked) { try await journal.identityScope(for: sourceID) }
        }
    }
}


extension EventDeliverySourceSetupTests {
    private static func recordIdentity(_ journal: EventDeliveryJournal, sourceID: UUID) async throws -> BusinessIdentifier {
        let scope = try await journal.identityScope(for: sourceID)
        return try scope.sourceRecord(
            adapterID: "healthkit",
            sourceType: "heart-rate",
            repositoryScope: .init(system: "https://test.example/repositories", value: "local"),
            nativeRecordID: "sample-1"
        ).identifier.identifier
    }

    private static func expectRestored(
        url: URL, setup: EventDeliveryJournal.SourceSetup, key: [Data], identity: BusinessIdentifier, sourceID: UUID
    ) async throws {
        let journal = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
        #expect(try await journal.sourceSetup(for: setup.localID) == setup)
        #expect(try await recordIdentity(journal, sourceID: sourceID) == identity)
        let connection = try DeliverySQLite(url: url)
        let keySQL = "SELECT privacy_key FROM source_state WHERE local_id = ?"
        let restoredKey = try connection.query(keySQL, [.text(setup.localID.uuidString.lowercased())]) {
            try DeliverySQLite.blob($0, 0)
        }
        #expect(restoredKey == key)
        connection.close()
        await journal.close()
    }
}
