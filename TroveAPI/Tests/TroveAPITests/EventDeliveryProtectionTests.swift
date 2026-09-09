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


struct EventDeliveryProtectionTests {
    @Test
    func newJournalHasOwnerOnlyPermissions() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(attributes[.posixPermissions] as? Int == 0o600)
            #expect(attributes[.referenceCount] as? Int == 1)
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
        }
    }

    @Test(arguments: [0o644, 0o660, 0o666, 0o400, 0o1600])
    func unsafeEstablishedFileIsRejectedWithoutRepairOrDataLoss(permissions: Int) async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let ids = try await DeliveryFixture.stage(journal, changes: ["preserve"])
            await journal.close()
            let original = try Data(contentsOf: url)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            #expect(throws: EventDeliveryJournal.JournalError.unsafeStorage) {
                try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(attributes[.posixPermissions] as? Int == permissions)
            #expect(try Data(contentsOf: url) == original)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            #expect(try await reopened.pendingDeliveryIDs() == ids)
            await reopened.close()
        }
    }

    @Test(arguments: [0o750, 0o755, 0o770, 0o777])
    func sharedDirectoryIsRejectedBeforeCreatingAFile(permissions: Int) async throws {
        try await DeliveryFixture.withJournal { journal, url in
            await journal.close()
            let directory = url.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            let newURL = directory.appendingPathComponent("must-not-create.sqlite")
            #expect(throws: EventDeliveryJournal.JournalError.unsafeStorage) {
                try EventDeliveryJournal(url: newURL, scope: DeliveryFixture.scope, mode: .createNew)
            }
            #expect(!FileManager.default.fileExists(atPath: newURL.path))
            #expect(throws: EventDeliveryJournal.JournalError.unsafeStorage) {
                try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            #expect(attributes[.posixPermissions] as? Int == permissions)
        }
    }

    @Test
    func hardLinkCannotAliasAnEstablishedJournal() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            _ = try await DeliveryFixture.stage(journal, changes: ["preserve"])
            await journal.close()
            let original = try Data(contentsOf: url)
            let alias = url.deletingLastPathComponent().appendingPathComponent("alias.sqlite")
            try FileManager.default.linkItem(at: url, to: alias)
            for candidate in [url, alias] {
                #expect(throws: EventDeliveryJournal.JournalError.unsafeStorage) {
                    try EventDeliveryJournal(url: candidate, scope: DeliveryFixture.scope, mode: .openExisting)
                }
                #expect(try Data(contentsOf: candidate) == original)
            }
        }
    }

    #if os(macOS)
    @Test(arguments: [false, true])
    func extendedACLsCannotBypassPrivateModeBits(directory: Bool) async throws {
        try await DeliveryFixture.withJournal { journal, url in
            await journal.close()
            let target = directory ? url.deletingLastPathComponent() : url
            let change = Process()
            change.executableURL = URL(fileURLWithPath: "/bin/chmod")
            change.arguments = ["+a", "everyone allow read", target.path]
            try change.run()
            change.waitUntilExit()
            try #require(change.terminationStatus == 0)
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            #expect(attributes[.posixPermissions] as? Int == (directory ? 0o700 : 0o600))
            #expect(throws: EventDeliveryJournal.JournalError.unsafeStorage) {
                try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            }
        }
    }
    #endif
}
