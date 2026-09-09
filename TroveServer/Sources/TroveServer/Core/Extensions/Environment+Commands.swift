//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Vapor


extension Environment {
    // Use the parsed command position, never an option value that happens to match a command.
    var isServing: Bool {
        !["migrate", "revert", "cleanup-artifacts"].contains(commandInput.arguments.first ?? "serve")
    }

    var isDatabaseMigration: Bool {
        ["migrate", "revert"].contains(commandInput.arguments.first ?? "serve")
    }
}
