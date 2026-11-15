//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import AppAuth
import Foundation


/// Route SDK state changes to the account owner without moving token objects between executors.
final class KeycloakAuthStateObserver: NSObject, OIDAuthStateChangeDelegate {
    private let onChange: @MainActor @Sendable () -> Void

    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
    }

    func didChange(_ state: OIDAuthState) {
        Task { @MainActor [onChange] in onChange() }
    }
}
