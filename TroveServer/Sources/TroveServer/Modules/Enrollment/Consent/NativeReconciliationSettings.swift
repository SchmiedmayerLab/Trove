//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Grove


/// How long one online request authorizes the bounded sweep of an ended sleep or workout window.
final class NativeReconciliationSettings: Module, Sendable {
    enum ConfigurationError: Error { case invalidLeaseDuration }

    static let defaultLeaseDuration: TimeInterval = 15 * 60
    let leaseDuration: TimeInterval

    init(leaseDuration: TimeInterval = NativeReconciliationSettings.defaultLeaseDuration) throws {
        guard leaseDuration.isFinite, leaseDuration > 0 else { throw ConfigurationError.invalidLeaseDuration }
        self.leaseDuration = leaseDuration
    }

    convenience init(seconds: String?) throws {
        guard let seconds else {
            try self.init()
            return
        }
        guard let duration = TimeInterval(seconds) else { throw ConfigurationError.invalidLeaseDuration }
        try self.init(leaseDuration: duration)
    }
}
