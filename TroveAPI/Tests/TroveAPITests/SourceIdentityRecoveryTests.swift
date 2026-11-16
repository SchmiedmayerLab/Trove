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


struct SourceIdentityRecoveryTests {
    @Test
    func twoInstallationsRecoverTheSameIdentityWithIndependentCredentialsAndCursors() async throws {
        try await DeliveryFixture.withJournal { first, url in
            let original = try await first.sourceSetup(for: DeliveryFixture.epoch)
            let second = try EventDeliveryJournal(
                url: url.deletingLastPathComponent().appendingPathComponent("second.sqlite"), scope: DeliveryFixture.scope, mode: .createNew
            )
            do {
                let pending = try await second.createSource(localID: UUID(), queryDefinition: Data([2]))
                var registration = try #require(original.binding)
                registration.installation.registrationID = pending.localID.uuidString.lowercased()
                #expect(registration.source.keyID != registration.installation.registrationID)
                try await second.confirmSource(registration, for: pending, identityKey: DeliveryFixture.identityKey)
                #expect(try await Self.identity(first) == Self.identity(second))
                #expect(try await first.installationCredential(for: original.localID) != second.installationCredential(for: pending.localID))
                let checkpoint = try await first.checkpoint(for: DeliveryFixture.sourceID)
                _ = try await first.stage(from: checkpoint, nextCursor: Data([9]), payloads: [])
                #expect(try await second.checkpoint(for: DeliveryFixture.sourceID).cursor == nil)
                registration.installation.revokedAt = registration.installation.createdAt
                try await second.confirmSource(registration, for: pending)
                await #expect(throws: DeliveryJournalError.sourceRevoked) { try await Self.identity(second) }
                _ = try await Self.identity(first)
            } catch {
                await second.close()
                throw error
            }
            await second.close()
        }
    }

    @Test
    func pendingSetupHasOnlyInstallationProofAndCannotAcceptMissingOrChangedIdentityKeys() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let pending = try await journal.createSource(localID: UUID(), queryDefinition: Data([2]))
            let proof = try await journal.installationCredential(for: pending.localID)
            #expect(proof.count == 32)
            let connection = try DeliverySQLite(url: url)
            let keyKinds = try connection.query(
                "SELECT typeof(privacy_key) FROM source_state WHERE local_id = ?", [.text(pending.localID.uuidString.lowercased())]
            ) {
                try DeliverySQLite.text($0, 0)
            }
            connection.close()
            #expect(keyKinds == ["null"])
            let binding = DeliveryFixture.binding(sourceID: UUID(), registrationID: pending.localID)
            await #expect(throws: DeliveryJournalError.sourceConflict) { try await journal.confirmSource(binding, for: pending) }
            #expect(try await journal.sourceSetup(for: pending.localID) == pending)
            let accepted = try await journal.confirmSource(binding, for: pending, identityKey: DeliveryFixture.identityKey)
            await #expect(throws: DeliveryJournalError.sourceConflict) {
                try await journal.confirmSource(binding, for: pending, identityKey: Data(repeating: 0x43, count: 32))
            }
            #expect(try await journal.sourceSetup(for: pending.localID) == accepted)
            #expect(try await journal.installationCredential(for: pending.localID) == proof)
        }
    }
}


extension SourceIdentityRecoveryTests {
    private static func identity(_ journal: EventDeliveryJournal) async throws -> BusinessIdentifier {
        let scope = try await journal.identityScope(for: DeliveryFixture.sourceID)
        return try scope.sourceRecord(
            adapterID: "healthkit",
            sourceType: "heart-rate",
            repositoryScope: .init(system: "https://test.example/repositories", value: "shared"),
            nativeRecordID: "shared-healthkit-uuid"
        ).identifier.identifier
    }
}
