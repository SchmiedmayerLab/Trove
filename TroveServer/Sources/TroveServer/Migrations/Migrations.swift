//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Vapor


/// Registers all database migrations across every database.
public func configureMigrations(for app: Application) {
    configurePostgresMigrations(for: app)
    configureTimescaleMigrations(for: app)
}
