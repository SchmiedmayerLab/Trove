//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import CryptoKit
import Foundation
import TroveAPIClient


enum HealthDataStorage {
    static func directory(for scope: EventDeliveryJournal.Scope, root: URL) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(scope)).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: "HealthDelivery", directoryHint: .isDirectory).appending(path: digest, directoryHint: .isDirectory)
    }

    /// Creation is an explicit participant action. A present directory with a missing or
    /// damaged database is an error, never an invitation to replace keys and checkpoints.
    nonisolated static func open(scope: EventDeliveryJournal.Scope, root: URL, create: Bool) async throws -> EventDeliveryJournal? {
        var directory = try directory(for: scope, root: root)
        let manager = FileManager.default
        var exists = true
        do {
            _ = try manager.attributesOfItem(atPath: directory.path)
        } catch CocoaError.fileReadNoSuchFile {
            exists = false
        }
        guard exists || create else {
            return nil
        }
        if !exists {
            let attributes: [FileAttributeKey: Any] = [
                .posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ]
            try manager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: attributes)
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: attributes)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
        }
        return try EventDeliveryJournal(
            url: directory.appending(path: "delivery.sqlite"), scope: scope, mode: exists ? .openExisting : .createNew
        )
    }
}
