//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

actor DeliveryTestSession {
    private var active = true

    func invalidate() {
        active = false
    }

    func validate() throws {
        guard active else { throw CancellationError() }
    }
}
