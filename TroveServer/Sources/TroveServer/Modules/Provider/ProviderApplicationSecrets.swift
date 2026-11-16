//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Operator-owned application credentials are independent of encrypted participant tokens and API status.
struct ProviderApplicationSecrets: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let values: [UUID: String]

    var description: String { "ProviderApplicationSecrets(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }

    init(_ values: [UUID: String]) throws {
        guard values.count <= 128, values.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 16_384 }) else {
            throw ProviderFailure.invalidConfiguration
        }
        self.values = values
    }

    func secret(for registrationID: UUID) throws -> String {
        guard let value = values[registrationID] else { throw ProviderFailure.invalidConfiguration }
        return value
    }
}
