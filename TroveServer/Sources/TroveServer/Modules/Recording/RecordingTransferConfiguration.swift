//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


extension RecordingTransferService.Limits {
    enum ConfigurationError: Error { case invalidSetting }

    init(storedBytes: String?, sourceBytes: String?, leaseSeconds: String?) throws {
        try self.init(
            storedBytes: Self.integer(storedBytes, fallback: Self.standard.storedBytes),
            sourceBytes: Self.integer(sourceBytes, fallback: Self.standard.sourceBytes),
            leaseDuration: TimeInterval(Self.integer(leaseSeconds, fallback: Int(Self.standard.leaseDuration)))
        )
    }

    private static func integer(_ value: String?, fallback: Int) throws -> Int {
        guard let value else {
            return fallback
        }
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(value) else {
            throw ConfigurationError.invalidSetting
        }
        return number
    }
}
